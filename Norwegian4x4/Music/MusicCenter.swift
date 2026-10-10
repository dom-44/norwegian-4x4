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
        spotify.onAuthorized = { [weak self] in
            guard let self else { return }
            prepareAutoMix(force: autoMix.state == .needsAuthorization)
        }
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
    /// usable token the builder shows "connect again" instead; nothing here
    /// switches apps on its own.
    func prepareAutoMix(force: Bool) {
        guard preferences.autoMixEnabled, let settings = preferences.autoMix, !autoMix.isBuilding else { return }
        guard force || autoMix.isStale(for: settings) else { return }
        guard let token = spotify.webAPIToken else { autoMix.markNeedsAuthorization(); return }
        Task {
            await autoMix.build(settings: settings, token: token)
            // Takes effect from the next phase change, also mid-workout.
            coordinator.updateSelections(effectivePreferences)
        }
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
