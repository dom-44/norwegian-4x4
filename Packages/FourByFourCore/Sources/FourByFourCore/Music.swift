import Foundation

public enum MusicSlot: String, Codable, CaseIterable, Sendable, Identifiable {
    case warmUp, highIntensity, recovery, coolDown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .warmUp: return "Warm-up"
        case .highIntensity: return "High-intensity intervals"
        case .recovery: return "Active recovery"
        case .coolDown: return "Cool-down"
        }
    }
}

public enum MusicProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, manual, spotify, youtube

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "No music"
        case .manual: return "Manual"
        case .spotify: return "Spotify"
        case .youtube: return "YouTube"
        }
    }
}

/// A playlist / album / video the user associated with a slot.
/// `uri` is a Spotify URI (`spotify:playlist:…`) or an https YouTube URL.
public struct MusicSelection: Codable, Equatable, Sendable {
    public var title: String
    public var uri: String
    /// Set for generated auto-mix playlists: number of tracks, so repeated
    /// phases can start further into the playlist instead of on the same song.
    public var trackCount: Int?
    /// Track to start at (0-based); nil = start of the playlist.
    public var startIndex: Int?

    public init(title: String, uri: String, trackCount: Int? = nil, startIndex: Int? = nil) {
        self.title = title
        self.uri = uri
        self.trackCount = trackCount
        self.startIndex = startIndex
    }
}

public struct MusicPreferences: Codable, Equatable, Sendable {
    public var provider: MusicProviderKind
    /// Try to change music automatically at phase transitions when the
    /// provider supports it. Otherwise only spoken prompts are given.
    public var autoSwitch: Bool
    public var warmUp: MusicSelection?
    public var highIntensity: MusicSelection?
    public var recovery: MusicSelection?
    public var coolDown: MusicSelection?
    /// Speak "switch to your … playlist" when music has to be changed by hand.
    public var spokenSwitchPrompts: Bool
    /// Spotify only: genre-based playlists built before each workout. Optional
    /// so settings saved by older versions still decode.
    public var autoMix: AutoMixSettings?

    public var autoMixEnabled: Bool { provider == .spotify && autoMix?.enabled == true }

    public init(provider: MusicProviderKind = .none, autoSwitch: Bool = true, spokenSwitchPrompts: Bool = true) {
        self.provider = provider
        self.autoSwitch = autoSwitch
        self.spokenSwitchPrompts = spokenSwitchPrompts
    }

    public subscript(slot: MusicSlot) -> MusicSelection? {
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
}

public struct MusicCapabilities: Equatable, Sendable {
    /// Can start a selected playlist without user interaction.
    public var canSwitchAutomatically: Bool
    /// Switching is only possible while this app is in the foreground.
    public var requiresForeground: Bool
    public var canPauseResume: Bool
    public var canReadPlaybackState: Bool

    public init(canSwitchAutomatically: Bool, requiresForeground: Bool, canPauseResume: Bool, canReadPlaybackState: Bool) {
        self.canSwitchAutomatically = canSwitchAutomatically
        self.requiresForeground = requiresForeground
        self.canPauseResume = canPauseResume
        self.canReadPlaybackState = canReadPlaybackState
    }

    public static let none = MusicCapabilities(canSwitchAutomatically: false, requiresForeground: false, canPauseResume: false, canReadPlaybackState: false)
}

public enum MusicProviderError: Error, Equatable, Sendable {
    case notConfigured
    case appNotInstalled
    case notAuthorized
    case notConnected
    case unsupported
    case requiresForeground
    case commandFailed(String)

    public var message: String {
        switch self {
        case .notConfigured: return "Music provider is not configured."
        case .appNotInstalled: return "The music app is not installed."
        case .notAuthorized: return "Not authorized. Connect again from Music settings."
        case .notConnected: return "Not connected to the music app."
        case .unsupported: return "This action is not supported by the provider."
        case .requiresForeground: return "Music can only be switched while the app is open."
        case .commandFailed(let reason): return "Music command failed: \(reason)"
        }
    }
}

/// A music backend. The workout engine never talks to providers; only the
/// `MusicCoordinator` does, and it never blocks or fails the workout.
@MainActor
public protocol MusicProvider: AnyObject {
    var kind: MusicProviderKind { get }
    var capabilities: MusicCapabilities { get }
    /// Start playing `selection`. Must not trigger interactive authorization.
    func play(_ selection: MusicSelection, appIsActive: Bool) async throws
    func pause() async throws
    func resume() async throws
}

/// Provider for "No music": does nothing.
@MainActor
public final class NoMusicProvider: MusicProvider {
    public init() {}
    public let kind: MusicProviderKind = .none
    public let capabilities: MusicCapabilities = .none
    public func play(_ selection: MusicSelection, appIsActive: Bool) async throws {}
    public func pause() async throws {}
    public func resume() async throws {}
}

/// Provider for manual mode: the user runs any music app themselves and the
/// app only gives spoken / visual prompts. Always available.
@MainActor
public final class ManualMusicProvider: MusicProvider {
    public init() {}
    public let kind: MusicProviderKind = .manual
    public let capabilities: MusicCapabilities = .none
    public func play(_ selection: MusicSelection, appIsActive: Bool) async throws { throw MusicProviderError.unsupported }
    public func pause() async throws { throw MusicProviderError.unsupported }
    public func resume() async throws { throw MusicProviderError.unsupported }
}

public enum MusicOutcome: Equatable, Sendable {
    /// Nothing to do (no music, no selection for the slot, or already playing it).
    case nothing
    case switched(MusicSlot, MusicSelection)
    /// The user should switch music by hand. `reason` is nil in manual mode.
    case manualPrompt(MusicSlot, MusicSelection?, reason: MusicProviderError?)
}

/// Maps workout phases to music and talks to the selected provider.
///
/// Guarantees:
/// * Never throws; failures become `.manualPrompt` outcomes.
/// * After `maxConsecutiveFailures` failures, automatic switching is disabled
///   for the rest of the session (no reconnect storms, no repeated prompts).
/// * A failed attempt is not retried for `retryBackoff` seconds.
@MainActor
public final class MusicCoordinator {
    public static let maxConsecutiveFailures = 3
    public static let retryBackoff: TimeInterval = 30

    public private(set) var provider: MusicProvider
    public private(set) var preferences: MusicPreferences
    public private(set) var lastOutcome: MusicOutcome = .nothing
    public private(set) var activeSlot: MusicSlot?
    /// Selection the provider last confirmed playing.
    public private(set) var playingSelection: MusicSelection?
    public private(set) var consecutiveFailures = 0
    public private(set) var autoSwitchSuspended = false
    /// How often each slot has started this session (for playlist rotation).
    private var repetitions: [MusicSlot: Int] = [:]
    private var lastFailureAt: TimeInterval?
    private let clock: () -> TimeInterval

    public init(provider: MusicProvider, preferences: MusicPreferences, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.provider = provider
        self.preferences = preferences
        self.clock = clock
    }

    public func configure(provider: MusicProvider, preferences: MusicPreferences) {
        self.provider = provider
        self.preferences = preferences
        resetSession()
    }

    /// Replaces the selections mid-session (e.g. an auto mix finished building)
    /// without forgetting what is playing or the failure state.
    public func updateSelections(_ preferences: MusicPreferences) {
        self.preferences = preferences
    }

    public func resetSession() {
        repetitions = [:]
        activeSlot = nil
        playingSelection = nil
        consecutiveFailures = 0
        autoSwitchSuspended = false
        lastFailureAt = nil
        lastOutcome = .nothing
    }

    @discardableResult
    public func phaseDidStart(_ kind: PhaseKind, appIsActive: Bool) async -> MusicOutcome {
        let outcome = await decide(slot: kind.musicSlot, appIsActive: appIsActive)
        lastOutcome = outcome
        return outcome
    }

    private func decide(slot: MusicSlot, appIsActive: Bool) async -> MusicOutcome {
        guard provider.kind != .none else { return .nothing }
        let repetition = repetitions[slot, default: 0]
        repetitions[slot] = repetition + 1
        let selection = preferences[slot].map { Self.rotated($0, repetition: repetition) }

        if provider.kind == .manual {
            guard slot != activeSlot else { return .nothing }
            activeSlot = slot
            return .manualPrompt(slot, selection, reason: nil)
        }

        guard let selection else { return .nothing }
        // Same playlist is already playing (e.g. slots share a playlist).
        if selection == playingSelection { activeSlot = slot; return .nothing }

        let caps = provider.capabilities
        guard preferences.autoSwitch, caps.canSwitchAutomatically else {
            activeSlot = slot
            return .manualPrompt(slot, selection, reason: caps.canSwitchAutomatically ? nil : .unsupported)
        }
        if autoSwitchSuspended {
            activeSlot = slot
            return .manualPrompt(slot, selection, reason: .notConnected)
        }
        if caps.requiresForeground && !appIsActive {
            activeSlot = slot
            return .manualPrompt(slot, selection, reason: .requiresForeground)
        }
        if let last = lastFailureAt, clock() - last < Self.retryBackoff {
            activeSlot = slot
            return .manualPrompt(slot, selection, reason: .notConnected)
        }

        do {
            try await provider.play(selection, appIsActive: appIsActive)
            consecutiveFailures = 0
            lastFailureAt = nil
            activeSlot = slot
            playingSelection = selection
            return .switched(slot, selection)
        } catch {
            consecutiveFailures += 1
            lastFailureAt = clock()
            if consecutiveFailures >= Self.maxConsecutiveFailures { autoSwitchSuspended = true }
            activeSlot = slot
            let reason = (error as? MusicProviderError) ?? .commandFailed(String(describing: error))
            return .manualPrompt(slot, selection, reason: reason)
        }
    }

    /// For generated playlists, the n-th repetition of a phase starts
    /// `tracksPerRepetition × n` tracks in (wrapping around).
    static func rotated(_ selection: MusicSelection, repetition: Int) -> MusicSelection {
        guard let count = selection.trackCount, count > 0 else { return selection }
        var copy = selection
        copy.startIndex = (repetition * AutoMixSettings.tracksPerRepetition) % count
        return copy
    }

    /// Best effort; errors are swallowed.
    public func pause() async {
        guard provider.capabilities.canPauseResume else { return }
        try? await provider.pause()
    }

    public func resume() async {
        guard provider.capabilities.canPauseResume else { return }
        try? await provider.resume()
    }
}
