import AuthenticationServices
import FourByFourCore
import Foundation
import Observation

/// Shown on the workout screen when music has to be changed by hand.
struct MusicPrompt: Equatable {
    var slot: MusicSlot
    var selection: MusicSelection?
    var provider: MusicProviderKind
    var reason: String?
}

/// App-side owner of the music providers and the `MusicCoordinator`.
@Observable
@MainActor
final class MusicCenter {
    let spotify = SpotifyMusicProvider()
    let youtube = YouTubeMusicProvider()
    let autoMix = AutoMixBuilder()
    /// Separate Web API sign-in for the auto mix (the App Remote token can't search).
    let webAuth = SpotifyWebAuth()
    @ObservationIgnored private let manual = ManualMusicProvider()
    @ObservationIgnored private let silent = NoMusicProvider()
    @ObservationIgnored private let coordinator: MusicCoordinator

    private(set) var preferences: MusicPreferences
    private(set) var prompt: MusicPrompt? = nil
    private(set) var lastSwitched: MusicSelection? = nil

    init(preferences: MusicPreferences) {
        self.preferences = preferences
        coordinator = MusicCoordinator(provider: NoMusicProvider(), preferences: preferences)
        coordinator.configure(provider: provider(for: preferences.provider), preferences: effectivePreferences)
    }

    var providerKind: MusicProviderKind { preferences.provider }

    func update(preferences: MusicPreferences) {
        guard preferences != self.preferences else { return }
        self.preferences = preferences
        coordinator.configure(provider: provider(for: preferences.provider), preferences: effectivePreferences)
    }

    /// The user's settings with generated auto-mix playlists filled in.
    /// A phase without a generated playlist keeps the user's own link.
    var effectivePreferences: MusicPreferences {
        guard preferences.autoMixEnabled else { return preferences }
        var prefs = preferences
        for slot in MusicSlot.allCases {
            if let generated = autoMix.selections[slot] { prefs[slot] = generated }
        }
        return prefs
    }

    /// Builds a fresh auto mix if needed (or always with `force`). Without a
    /// Web API sign-in the builder shows "sign in" instead; nothing here opens
    /// a login on its own.
    func prepareAutoMix(force: Bool) {
        guard preferences.autoMixEnabled, let settings = preferences.autoMix, !autoMix.isBuilding else { return }
        guard force || autoMix.isStale(for: settings) else { return }
        guard webAuth.isSignedIn else { autoMix.markNeedsAuthorization(); return }
        Task {
            let token: String
            do {
                token = try await webAuth.validAccessToken()
            } catch {
                autoMix.markNeedsAuthorization()
                return
            }
            await autoMix.build(settings: settings, token: token)
            // Takes effect from the next phase change, also mid-workout.
            coordinator.updateSelections(effectivePreferences)
        }
    }

    // MARK: Ratings (workout screen)

    /// Rating of the song Spotify is playing now, if it is a track.
    var currentRating: TrackRatings.Rating? {
        spotify.trackURI.flatMap(TrackRatings.trackID(fromURI:)).flatMap { autoMix.ratings.rating(for: $0) }
    }

    /// 👍: picked more often in future mixes. Tapping again clears it.
    func toggleLikeCurrentTrack() {
        guard let id = spotify.trackURI.flatMap(TrackRatings.trackID(fromURI:)) else { return }
        autoMix.updateRatings { ratings in
            if ratings.rating(for: id) == .liked { ratings.clear(id) } else { ratings.like(id) }
        }
    }

    /// 👎: skips the song, removes it from the generated playlists and never
    /// picks it again. Removal is best effort (needs the Web API sign-in).
    func dislikeCurrentTrack() {
        guard let uri = spotify.trackURI, let id = TrackRatings.trackID(fromURI: uri) else { return }
        autoMix.updateRatings { $0.dislike(id) }
        spotify.perform(.next)
        let playlists = autoMix.playlistIDs
        guard webAuth.isSignedIn, !playlists.isEmpty else { return }
        Task {
            guard let token = try? await webAuth.validAccessToken() else { return }
            let api = SpotifyWebAPI(token: token)
            for playlist in playlists {
                try? await api.removeItems(playlistID: playlist, uris: [uri])
            }
        }
    }

    func resetRatings() {
        autoMix.updateRatings { $0 = TrackRatings() }
    }

    /// User tapped "Sign in": shows Spotify's login sheet, then builds the mix.
    /// Returns an error message to show, or nil.
    func signInForAutoMix() async -> String? {
        do {
            try await webAuth.signIn()
        } catch let error as WebAPIError {
            return error.message
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return nil
        } catch {
            return error.localizedDescription
        }
        prepareAutoMix(force: true)
        return nil
    }

    private func provider(for kind: MusicProviderKind) -> MusicProvider {
        switch kind {
        case .none: return silent
        case .manual: return manual
        case .spotify: return spotify
        case .youtube: return youtube
        }
    }

    func beginSession() {
        coordinator.resetSession()
        prompt = nil
        lastSwitched = nil
        if preferences.provider == .spotify { spotify.reconnectQuietly() }
    }

    func endSession() {
        prompt = nil
        coordinator.resetSession()
    }

    /// Called on every phase start. Returns text to speak, if any.
    func phaseStarted(_ kind: PhaseKind, appIsActive: Bool) async -> String? {
        let outcome = await coordinator.phaseDidStart(kind, appIsActive: appIsActive)
        switch outcome {
        case .nothing:
            return nil
        case .switched(_, let selection):
            prompt = nil
            lastSwitched = selection
            return nil
        case .manualPrompt(let slot, let selection, let reason):
            prompt = MusicPrompt(slot: slot, selection: selection, provider: preferences.provider,
                                 reason: reason == .requiresForeground || reason == .unsupported ? nil : reason?.message)
            return preferences.spokenSwitchPrompts ? CoachingScript.musicPrompt(slot: slot, selection: selection) : nil
        }
    }

    func dismissPrompt() { prompt = nil }

    /// User tapped "Open" / "Play" for a slot (foreground, user-initiated).
    func openSelection(for slot: MusicSlot) {
        guard let selection = effectivePreferences[slot] else { return }
        switch preferences.provider {
        case .spotify:
            if spotify.status == .connected {
                Task {
                    if (try? await spotify.play(selection, appIsActive: true)) != nil { lastSwitched = selection; prompt = nil }
                }
            } else {
                spotify.authorizeAndPlay(uri: selection.uri)
                prompt = nil
            }
        case .youtube:
            youtube.open(selection)
            prompt = nil
        case .manual, .none:
            prompt = nil
        }
    }

    func pauseMusic() { Task { await coordinator.pause() } }
    func resumeMusic() { Task { await coordinator.resume() } }

    func handleOpenURL(_ url: URL) -> Bool { spotify.handleOpenURL(url) }

    func appBecameActive() {
        spotify.refreshAvailability()
        if preferences.provider == .spotify, spotify.hasToken, spotify.status != .connected { spotify.reconnectQuietly() }
    }
}
