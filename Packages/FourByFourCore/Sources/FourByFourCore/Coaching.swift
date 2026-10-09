import Foundation

public enum TransitionTone: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, rising, falling, chime
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: return "None"
        case .rising: return "Rising"
        case .falling: return "Falling"
        case .chime: return "Chime"
        }
    }
}

public struct TransitionStyle: Codable, Equatable, Sendable {
    public var tone: TransitionTone
    public var haptic: Bool
    public init(tone: TransitionTone, haptic: Bool) {
        self.tone = tone
        self.haptic = haptic
    }
}

public struct CoachingSettings: Codable, Equatable, Sendable {
    public var voiceEnabled = true
    public var phaseAnnouncements = true
    public var midpointReminders = true
    public var finalCountdown = true
    public var transitionSounds = true
    public var haptics = true
    /// Backup local notifications for phase changes while the screen is locked.
    public var lockScreenAlerts = true
    /// AVSpeechUtterance rate (0…1, 0.5 is the system default).
    public var speechRate: Double = 0.5
    public var warmUpStyle = TransitionStyle(tone: .chime, haptic: true)
    public var intervalStyle = TransitionStyle(tone: .rising, haptic: true)
    public var recoveryStyle = TransitionStyle(tone: .falling, haptic: true)
    public var coolDownStyle = TransitionStyle(tone: .chime, haptic: true)

    public init() {}

    public subscript(kind: PhaseKind) -> TransitionStyle {
        get {
            switch kind {
            case .warmUp: return warmUpStyle
            case .interval: return intervalStyle
            case .recovery: return recoveryStyle
            case .coolDown: return coolDownStyle
            }
        }
        set {
            switch kind {
            case .warmUp: warmUpStyle = newValue
            case .interval: intervalStyle = newValue
            case .recovery: recoveryStyle = newValue
            case .coolDown: coolDownStyle = newValue
            }
        }
    }
}

public enum HapticCue: Equatable, Sendable {
    case phaseChange, countdownTick, completed
}

public enum SoundCue: Equatable, Sendable {
    case transition(TransitionTone)
    case countdownTick
    case completed
}

/// What to say / play / feel for a workout event.
public struct CoachingAction: Equatable, Sendable {
    public var speech: String?
    public var sound: SoundCue?
    public var haptic: HapticCue?

    public init(speech: String? = nil, sound: SoundCue? = nil, haptic: HapticCue? = nil) {
        self.speech = speech
        self.sound = sound
        self.haptic = haptic
    }

    public var isEmpty: Bool { speech == nil && sound == nil && haptic == nil }
}

/// Builds concise coaching lines locally (no network / AI service).
public enum CoachingScript {
    public static func action(for cue: WorkoutCue, plan: WorkoutPlan, maxHR: Int, currentBPM: Int?, remaining: TimeInterval, settings: CoachingSettings) -> CoachingAction {
        let phase = plan.phases[cue.phaseIndex]
        let style = settings[phase.kind]
        var action = CoachingAction()

        switch cue.kind {
        case .phaseStart(let late):
            if settings.transitionSounds, style.tone != .none, !late { action.sound = .transition(style.tone) }
            if settings.haptics, style.haptic { action.haptic = .phaseChange }
            if settings.voiceEnabled, settings.phaseAnnouncements {
                action.speech = late ? catchUpLine(phase: phase, remaining: remaining) : startLine(phase: phase, maxHR: maxHR)
            }
        case .midpoint:
            if settings.voiceEnabled, settings.midpointReminders {
                action.speech = midpointLine(phase: phase, maxHR: maxHR, bpm: currentBPM, remaining: remaining)
            }
        case .countdown(let seconds):
            guard settings.finalCountdown else { break }
            if seconds == 10 {
                if settings.voiceEnabled { action.speech = cue.phaseIndex == plan.phases.count - 1 ? "Ten seconds to finish." : "Ten seconds." }
            } else {
                if settings.transitionSounds { action.sound = .countdownTick }
                if settings.haptics { action.haptic = .countdownTick }
            }
        }
        return action
    }

    public static func completionAction(settings: CoachingSettings) -> CoachingAction {
        CoachingAction(
            speech: settings.voiceEnabled ? "Workout complete. Great work." : nil,
            sound: settings.transitionSounds ? .completed : nil,
            haptic: settings.haptics ? .completed : nil
        )
    }

    public static func startLine(phase: PhaseDefinition, maxHR: Int) -> String {
        switch phase.kind {
        case .warmUp:
            return "Warm-up. Start easy and gradually increase your pace."
        case .interval:
            let target = HeartRateZones.target(for: .interval, maxHR: maxHR)
            let targetText = target.map { " Target \($0.lower) to \($0.upper)." } ?? ""
            if phase.isFinalInterval && phase.number > 1 {
                return "Final interval. Maintain your effort.\(targetText)"
            }
            return "\(ordinal(phase.number)) interval. Increase your intensity.\(targetText)"
        case .recovery:
            return "Recovery. Reduce intensity but keep moving."
        case .coolDown:
            return "Cool-down. Gradually reduce your pace."
        }
    }

    static func catchUpLine(phase: PhaseDefinition, remaining: TimeInterval) -> String {
        "\(phase.name). \(spokenDuration(remaining)) remaining."
    }

    static func midpointLine(phase: PhaseDefinition, maxHR: Int, bpm: Int?, remaining: TimeInterval) -> String {
        let target = HeartRateZones.target(for: phase.kind, maxHR: maxHR)
        let status = HeartRateZones.status(bpm: bpm, target: target)
        switch phase.kind {
        case .interval:
            switch status {
            case .below: return "Halfway. Move toward your target heart rate."
            case .above: return "Halfway. You are above target, ease off slightly."
            default: return "Halfway. Hold your effort."
            }
        case .recovery:
            return "Next interval in \(spokenDuration(remaining)). Keep moving."
        default:
            return "Halfway."
        }
    }

    public static func musicPrompt(slot: MusicSlot, selection: MusicSelection?) -> String {
        if let selection, !selection.title.isEmpty { return "Switch music to \(selection.title)." }
        switch slot {
        case .highIntensity: return "Switch to your high-intensity music."
        case .recovery: return "Switch to your recovery music."
        case .warmUp: return "Start your warm-up music."
        case .coolDown: return "Switch to your cool-down music."
        }
    }

    static func ordinal(_ n: Int) -> String {
        let words = ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth"]
        return (1...words.count).contains(n) ? words[n - 1] : "Interval \(n),"
    }

    public static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        switch (m, s) {
        case (0, _): return "\(s) seconds"
        case (_, 0): return m == 1 ? "1 minute" : "\(m) minutes"
        case (_, 30): return m == 1 ? "1 and a half minutes" : "\(m) and a half minutes"
        default: return "\(m) minute\(m == 1 ? "" : "s") \(s) seconds"
        }
    }
}
