import FourByFourCore
import Foundation
import Observation
import os

/// Builds the genre-based "auto mix": searches Spotify per genre, checks tempo
/// and energy, and writes one private playlist per phase into the user's
/// Spotify account (reused between workouts, refilled each time).
///
/// Never touches the workout: on failure the previous mix (or the user's own
/// playlist links) stays in use.
@Observable
@MainActor
final class AutoMixBuilder {
    enum State: Equatable {
        case idle
        case building(String)
        case ready
        case failed(String)
        case needsAuthorization
    }

    private(set) var state: State = .idle
    /// Last successfully built playlist per phase (persisted).
    private(set) var selections: [MusicSlot: MusicSelection] = [:]
    private(set) var builtAt: Date?
    /// Phases that got no or too few fitting tracks in the last build.
    private(set) var missingSlots: [MusicSlot] = []

    var isBuilding: Bool { if case .building = state { return true } else { return false } }

    @ObservationIgnored private let log = Logger(subsystem: "Norwegian4x4", category: "AutoMix")
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var builtFor: AutoMixSettings?
    private static let selectionsKey = "autoMix.selections"
    private static let builtAtKey = "autoMix.builtAt"
    private static let settingsKey = "autoMix.settings"
    private static func playlistKey(_ slot: MusicSlot) -> String { "autoMix.playlist.\(slot.rawValue)" }

    /// Candidate tracks fetched per genre (search pages are 10 tracks).
    static let candidatesPerGenre = 60
    /// A phase needs at least this many tracks, otherwise it keeps the old playlist.
    static let minimumTracks = 3
    /// A mix older than this is rebuilt when the pre-workout screen opens.
    static let freshFor: TimeInterval = 30 * 60

    init() {
        if let data = defaults.data(forKey: Self.selectionsKey),
           let stored = try? JSONDecoder().decode([String: MusicSelection].self, from: data) {
            selections = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in MusicSlot(rawValue: key).map { ($0, value) } })
        }
        builtAt = defaults.object(forKey: Self.builtAtKey) as? Date
        if let data = defaults.data(forKey: Self.settingsKey) {
            builtFor = try? JSONDecoder().decode(AutoMixSettings.self, from: data)
        }
    }

    /// True when the mix should be rebuilt before the next workout.
    func isStale(for settings: AutoMixSettings) -> Bool {
        guard let builtAt, let builtFor, !selections.isEmpty else { return true }
        return builtFor != settings || Date().timeIntervalSince(builtAt) > Self.freshFor
    }

    func markNeedsAuthorization() {
        if !isBuilding { state = .needsAuthorization }
    }

    func build(settings: AutoMixSettings, token: String) async {
        guard !isBuilding else { return }
        let spotify = SpotifyWebAPI(token: token)
        // Named in error messages so a failure says which Spotify call broke.
        var step = "Search"
        do {
            // 1. Candidates per genre (each genre fetched once even if several phases use it).
            var candidates: [MusicGenre: [TrackCandidate]] = [:]
            for genre in Set(MusicSlot.allCases.map { settings[$0].genre }).sorted(by: { $0.rawValue < $1.rawValue }) {
                state = .building("Searching \(genre.displayName)…")
                candidates[genre] = try await fetchCandidates(for: genre, using: spotify)
            }

            // 2. Tempo and energy.
            step = "Tempo lookup"
            state = .building("Checking tempo…")
            let allIDs = candidates.values.flatMap { $0.map(\.id) }
            let features = await ReccoBeatsAPI().features(for: allIDs)
            guard !features.isEmpty else {
                state = .failed("Tempo data unavailable (ReccoBeats). Using the previous mix.")
                return
            }

            // 3. Pick per phase. Hardest phase first; a track is used only once.
            var rng = SystemRandomNumberGenerator()
            var used = Set<String>()
            var picks: [MusicSlot: [TrackCandidate]] = [:]
            for slot in [MusicSlot.highIntensity, .recovery, .warmUp, .coolDown] {
                let slotSettings = settings[slot]
                let pool = (candidates[slotSettings.genre] ?? []).filter { !used.contains($0.id) }
                let picked = TrackPicker.pick(from: pool, features: features, profile: slotSettings.tempo,
                                              count: AutoMixSettings.trackCount(for: slot), using: &rng)
                picked.forEach { used.insert($0.id) }
                picks[slot] = picked
                log.info("\(slot.rawValue, privacy: .public): \(picked.count) of \(pool.count) tracks fit")
            }

            // 4. Write playlists.
            step = "Writing playlists"
            state = .building("Writing playlists…")
            var built = selections
            var missing: [MusicSlot] = []
            for slot in MusicSlot.allCases {
                let tracks = picks[slot] ?? []
                guard tracks.count >= Self.minimumTracks else { missing.append(slot); continue }
                let id = try await writePlaylist(for: slot, genre: settings[slot].genre, uris: tracks.map(\.uri), using: spotify)
                built[slot] = MusicSelection(title: "\(settings[slot].genre.displayName) mix",
                                             uri: "spotify:playlist:\(id)", trackCount: tracks.count)
            }

            selections = built
            missingSlots = missing
            builtAt = Date()
            builtFor = settings
            persist()
            state = missing.count == MusicSlot.allCases.count
                ? .failed("No fitting songs found. Try other genres or wider tempo ranges.")
                : .ready
        } catch WebAPIError.needsAuthorization {
            state = .needsAuthorization
        } catch let error as WebAPIError {
            log.error("\(step, privacy: .public) failed: \(error.message, privacy: .public)")
            state = .failed("\(step) failed. \(error.message)")
        } catch {
            state = .failed("\(step) failed. \(error.localizedDescription)")
        }
    }

    private func fetchCandidates(for genre: MusicGenre, using spotify: SpotifyWebAPI) async throws -> [TrackCandidate] {
        var result: [TrackCandidate] = []
        var seen = Set<String>()
        for query in genre.searchQueries where result.count < Self.candidatesPerGenre {
            // Random start page so each workout draws from a different part of the results.
            var offset = Int.random(in: 0...10) * SpotifyWebAPI.searchPageSize
            var restartedAtZero = offset == 0
            var requests = 0
            while result.count < Self.candidatesPerGenre, requests < 10 {
                requests += 1
                let page = try await spotify.searchTracks(query: query, offset: offset)
                for track in page where seen.insert(track.id).inserted { result.append(track) }
                if page.count < SpotifyWebAPI.searchPageSize {
                    // Ran past the end of the results: wrap around once.
                    guard !restartedAtZero else { break }
                    restartedAtZero = true
                    offset = 0
                } else {
                    offset += SpotifyWebAPI.searchPageSize
                }
            }
        }
        return result
    }

    /// Reuses the phase's playlist if it still exists, otherwise creates it.
    private func writePlaylist(for slot: MusicSlot, genre: MusicGenre, uris: [String], using spotify: SpotifyWebAPI) async throws -> String {
        let key = Self.playlistKey(slot)
        if let existing = defaults.string(forKey: key) {
            do {
                try await spotify.replaceItems(playlistID: existing, uris: uris)
                return existing
            } catch WebAPIError.http(404, _) {
                defaults.removeObject(forKey: key) // deleted in Spotify; create a new one
            }
        }
        let id = try await spotify.createPlaylist(name: AutoMixSettings.playlistName(for: slot),
                                                  description: "Built by Norwegian 4x4 — \(genre.displayName), refreshed before each workout.")
        defaults.set(id, forKey: key)
        try await spotify.replaceItems(playlistID: id, uris: uris)
        return id
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: selections.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.selectionsKey)
        defaults.set(builtAt, forKey: Self.builtAtKey)
        defaults.set(try? JSONEncoder().encode(builtFor), forKey: Self.settingsKey)
    }
}
