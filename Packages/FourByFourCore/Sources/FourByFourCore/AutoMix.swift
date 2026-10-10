import Foundation

// "Auto mix": instead of pasting playlist links, the user picks a genre per
// phase. Before a workout the app searches Spotify for tracks of each genre,
// looks up tempo / energy (ReccoBeats; Spotify's own audio-features endpoint
// is closed to new apps), keeps the tracks that fit the phase and writes them
// into one private playlist per phase. Everything in this file is pure logic;
// networking lives in the app target.

public enum MusicGenre: String, Codable, CaseIterable, Sendable, Identifiable {
    case pop, dance, edm, house, techno, drumAndBass, hipHop, germanRap, rnb, rock, metal, punk, indie, latin, eighties, nineties, chill, acoustic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pop: return "Pop"
        case .dance: return "Dance"
        case .edm: return "EDM"
        case .house: return "House"
        case .techno: return "Techno"
        case .drumAndBass: return "Drum & Bass"
        case .hipHop: return "Hip-Hop"
        case .germanRap: return "Deutschrap"
        case .rnb: return "R&B"
        case .rock: return "Rock"
        case .metal: return "Metal"
        case .punk: return "Punk"
        case .indie: return "Indie"
        case .latin: return "Latin"
        case .eighties: return "80s"
        case .nineties: return "90s"
        case .chill: return "Chill"
        case .acoustic: return "Acoustic"
        }
    }

    /// Spotify search queries, best first. The `genre:` filter matches the
    /// artist's genres; the plain-text query is a fallback when it finds little.
    public var searchQueries: [String] {
        switch self {
        case .pop: return ["genre:\"pop\"", "pop hits"]
        case .dance: return ["genre:\"dance pop\"", "dance hits"]
        case .edm: return ["genre:\"edm\"", "edm"]
        case .house: return ["genre:\"house\"", "house music"]
        case .techno: return ["genre:\"techno\"", "techno"]
        case .drumAndBass: return ["genre:\"drum and bass\"", "drum and bass"]
        case .hipHop: return ["genre:\"hip hop\"", "hip hop"]
        case .germanRap: return ["genre:\"german hip hop\"", "deutschrap"]
        case .rnb: return ["genre:\"r&b\"", "r&b"]
        case .rock: return ["genre:\"rock\"", "rock"]
        case .metal: return ["genre:\"metal\"", "metal"]
        case .punk: return ["genre:\"punk\"", "punk rock"]
        case .indie: return ["genre:\"indie\"", "indie"]
        case .latin: return ["genre:\"latin\"", "reggaeton"]
        case .eighties: return ["year:1980-1989 genre:\"pop\"", "80s hits"]
        case .nineties: return ["year:1990-1999 genre:\"pop\"", "90s hits"]
        case .chill: return ["genre:\"chill\"", "chill"]
        case .acoustic: return ["genre:\"acoustic\"", "acoustic"]
        }
    }
}

/// What "fits" a phase: song tempo and Spotify-style energy (0…1).
public struct TempoProfile: Codable, Equatable, Sendable {
    public var bpm: BPMRange
    public var minEnergy: Double
    public var maxEnergy: Double

    public init(bpm: BPMRange, minEnergy: Double, maxEnergy: Double) {
        self.bpm = bpm
        self.minEnergy = minEnergy
        self.maxEnergy = maxEnergy
    }

    public static func standard(for slot: MusicSlot) -> TempoProfile {
        switch slot {
        case .warmUp: return TempoProfile(bpm: BPMRange(lower: 110, upper: 130), minEnergy: 0.5, maxEnergy: 0.85)
        case .highIntensity: return TempoProfile(bpm: BPMRange(lower: 145, upper: 175), minEnergy: 0.75, maxEnergy: 1.0)
        case .recovery: return TempoProfile(bpm: BPMRange(lower: 100, upper: 125), minEnergy: 0.4, maxEnergy: 0.8)
        case .coolDown: return TempoProfile(bpm: BPMRange(lower: 70, upper: 100), minEnergy: 0.0, maxEnergy: 0.55)
        }
    }

    /// Analysis often reports half or double the felt tempo (a 174 BPM drum &
    /// bass track as 87). Returns the variant that lands in range, if any.
    public func matchingTempo(_ tempo: Double) -> Double? {
        let range = Double(bpm.lower)...Double(bpm.upper)
        return [tempo, tempo * 2, tempo / 2].first { range.contains($0) }
    }

    public func energyFits(_ energy: Double) -> Bool { energy >= minEnergy && energy <= maxEnergy }

    /// Distance from a perfect fit; 0 = inside both ranges. Used to rank
    /// near misses when too few tracks match exactly.
    public func distance(tempo: Double, energy: Double) -> Double {
        let lower = Double(bpm.lower), upper = Double(bpm.upper)
        let tempoMiss = [tempo, tempo * 2, tempo / 2].map { t in t < lower ? lower - t : (t > upper ? t - upper : 0) }.min() ?? 0
        let energyMiss = energy < minEnergy ? minEnergy - energy : (energy > maxEnergy ? energy - maxEnergy : 0)
        // 0.1 energy ≈ 10 BPM.
        return tempoMiss + energyMiss * 100
    }
}

public struct AutoMixSlot: Codable, Equatable, Sendable {
    public var genre: MusicGenre
    public var tempo: TempoProfile

    public init(genre: MusicGenre, tempo: TempoProfile) {
        self.genre = genre
        self.tempo = tempo
    }
}

public struct AutoMixSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var warmUp: AutoMixSlot
    public var highIntensity: AutoMixSlot
    public var recovery: AutoMixSlot
    public var coolDown: AutoMixSlot

    public init(enabled: Bool = true,
                warmUp: AutoMixSlot = AutoMixSlot(genre: .pop, tempo: .standard(for: .warmUp)),
                highIntensity: AutoMixSlot = AutoMixSlot(genre: .edm, tempo: .standard(for: .highIntensity)),
                recovery: AutoMixSlot = AutoMixSlot(genre: .pop, tempo: .standard(for: .recovery)),
                coolDown: AutoMixSlot = AutoMixSlot(genre: .chill, tempo: .standard(for: .coolDown))) {
        self.enabled = enabled
        self.warmUp = warmUp
        self.highIntensity = highIntensity
        self.recovery = recovery
        self.coolDown = coolDown
    }

    public subscript(slot: MusicSlot) -> AutoMixSlot {
        get {
            switch slot {
            case .warmUp: return warmUp
            case .highIntensity: return highIntensity
            case .recovery: return recovery
            case .coolDown: return coolDown
            }
        }
        set {
            switch slot {
            case .warmUp: warmUp = newValue
            case .highIntensity: highIntensity = newValue
            case .recovery: recovery = newValue
            case .coolDown: coolDown = newValue
            }
        }
    }

    /// Tracks written to each phase playlist. Intervals and recoveries repeat,
    /// so their playlists hold enough tracks to start each repetition on new songs.
    public static func trackCount(for slot: MusicSlot) -> Int {
        switch slot {
        case .warmUp, .coolDown: return 6
        case .highIntensity, .recovery: return 12
        }
    }

    /// How far the start track advances with each repetition of a phase.
    public static let tracksPerRepetition = 2

    public static func playlistName(for slot: MusicSlot) -> String { "4x4 · \(slot.displayName)" }
}

public struct TrackCandidate: Equatable, Sendable {
    public var id: String
    public var uri: String
    public var name: String
    public var artist: String

    public init(id: String, uri: String, name: String, artist: String) {
        self.id = id
        self.uri = uri
        self.name = name
        self.artist = artist
    }
}

public struct AudioFeatures: Equatable, Sendable {
    public var tempo: Double
    public var energy: Double

    public init(tempo: Double, energy: Double) {
        self.tempo = tempo
        self.energy = energy
    }
}

public enum TrackPicker {
    /// Most tracks allowed from one artist in a phase playlist.
    public static let maxPerArtist = 2

    /// Picks up to `count` tracks for a phase: exact fits first (in random
    /// order, for variety between workouts), then the nearest misses. Tracks
    /// without analysis data are never used.
    public static func pick<R: RandomNumberGenerator>(from candidates: [TrackCandidate], features: [String: AudioFeatures],
                                                      profile: TempoProfile, count: Int, using rng: inout R) -> [TrackCandidate] {
        var seen = Set<String>()
        let analysed = candidates.filter { features[$0.id] != nil && seen.insert($0.id).inserted }

        var exact: [TrackCandidate] = []
        var near: [(TrackCandidate, Double)] = []
        for track in analysed {
            let f = features[track.id]!
            if profile.matchingTempo(f.tempo) != nil, profile.energyFits(f.energy) {
                exact.append(track)
            } else {
                near.append((track, profile.distance(tempo: f.tempo, energy: f.energy)))
            }
        }
        exact.shuffle(using: &rng)
        // Only modest misses (≈ 15 BPM or 0.15 energy) are acceptable fillers.
        let fillers = near.filter { $0.1 <= 15 }.sorted { $0.1 < $1.1 }.map(\.0)

        var picked: [TrackCandidate] = []
        var perArtist: [String: Int] = [:]
        for track in exact + fillers where picked.count < count {
            let key = track.artist.lowercased()
            guard perArtist[key, default: 0] < maxPerArtist else { continue }
            perArtist[key, default: 0] += 1
            picked.append(track)
        }
        return picked
    }
}

// MARK: - Response parsing

public enum SpotifySearchParser {
    struct Response: Decodable {
        struct Tracks: Decodable { var items: [Track?] }
        struct Track: Decodable {
            struct Artist: Decodable { var name: String }
            var id: String?
            var uri: String
            var name: String
            var artists: [Artist]
            var is_playable: Bool?
            var is_local: Bool?
        }
        var tracks: Tracks?
    }

    /// Track results of `GET /v1/search?type=track`. Skips local files and
    /// tracks Spotify reports as unplayable in the user's market.
    public static func tracks(from data: Data) throws -> [TrackCandidate] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.tracks?.items ?? []).compactMap { item in
            guard let item, let id = item.id, item.is_local != true, item.is_playable != false else { return nil }
            return TrackCandidate(id: id, uri: item.uri, name: item.name, artist: item.artists.first?.name ?? "")
        }
    }
}

public enum ReccoBeatsParser {
    /// The API accepts at most this many IDs per request.
    public static let maxIDsPerRequest = 40

    struct Response: Decodable {
        struct Item: Decodable {
            var href: String?
            var tempo: Double?
            var energy: Double?
        }
        var content: [Item]
    }

    /// `GET /v1/audio-features?ids=…` keyed by Spotify track ID. ReccoBeats
    /// uses its own IDs; the Spotify ID is the last path component of `href`.
    public static func features(from data: Data) throws -> [String: AudioFeatures] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var result: [String: AudioFeatures] = [:]
        for item in response.content {
            guard let href = item.href, let url = URL(string: href), url.host == "open.spotify.com",
                  let tempo = item.tempo, let energy = item.energy, tempo > 0 else { continue }
            result[url.lastPathComponent] = AudioFeatures(tempo: tempo, energy: energy)
        }
        return result
    }
}
