import Foundation

public enum PhaseKind: String, Codable, CaseIterable, Sendable {
    case warmUp, interval, recovery, coolDown

    public var displayName: String {
        switch self {
        case .warmUp: return "Warm-up"
        case .interval: return "High intensity"
        case .recovery: return "Active recovery"
        case .coolDown: return "Cool-down"
        }
    }

    public var musicSlot: MusicSlot {
        switch self {
        case .warmUp: return .warmUp
        case .interval: return .highIntensity
        case .recovery: return .recovery
        case .coolDown: return .coolDown
        }
    }
}

/// One phase of a concrete workout plan.
public struct PhaseDefinition: Codable, Equatable, Identifiable, Sendable {
    /// Position of the phase in the plan (0-based).
    public var id: Int
    public var kind: PhaseKind
    /// 1-based number for intervals and recoveries, 0 for warm-up / cool-down.
    public var number: Int
    public var duration: TimeInterval
    public var isFinalInterval: Bool

    public init(id: Int, kind: PhaseKind, number: Int, duration: TimeInterval, isFinalInterval: Bool = false) {
        self.id = id
        self.kind = kind
        self.number = number
        self.duration = duration
        self.isFinalInterval = isFinalInterval
    }

    public var name: String {
        switch kind {
        case .warmUp: return "Warm-up"
        case .interval: return "Interval \(number)"
        case .recovery: return "Recovery \(number)"
        case .coolDown: return "Cool-down"
        }
    }

    public var summary: String {
        switch kind {
        case .warmUp: return "Start easy and gradually increase your pace."
        case .interval: return "Hard, sustainable effort at 85–95% of your max heart rate."
        case .recovery: return "Reduce intensity but keep moving, 60–70% of max heart rate."
        case .coolDown: return "Gradually reduce your pace and let your heart rate settle."
        }
    }

    public var musicSlot: MusicSlot { kind.musicSlot }
}

/// User-editable durations. The plan is always derived from this so that the
/// structure (warm-up, N × interval/recovery, cool-down) stays valid.
public struct WorkoutConfiguration: Codable, Equatable, Sendable {
    public var warmUp: TimeInterval
    public var interval: TimeInterval
    public var recovery: TimeInterval
    public var intervalCount: Int
    public var coolDown: TimeInterval

    public init(warmUp: TimeInterval, interval: TimeInterval, recovery: TimeInterval, intervalCount: Int, coolDown: TimeInterval) {
        self.warmUp = warmUp
        self.interval = interval
        self.recovery = recovery
        self.intervalCount = intervalCount
        self.coolDown = coolDown
    }

    /// Standard Norwegian 4x4: 10 + 4×4 + 3×3 + 5 = 40 minutes.
    public static let standard = WorkoutConfiguration(warmUp: 600, interval: 240, recovery: 180, intervalCount: 4, coolDown: 300)

    public static let warmUpRange: ClosedRange<TimeInterval> = 0...1_800
    public static let intervalRange: ClosedRange<TimeInterval> = 30...900
    public static let recoveryRange: ClosedRange<TimeInterval> = 30...900
    public static let coolDownRange: ClosedRange<TimeInterval> = 0...1_800
    public static let intervalCountRange: ClosedRange<Int> = 1...8

    public var isStandard: Bool { self == .standard }

    /// Returns a copy with every value clamped to its allowed range.
    public func sanitized() -> WorkoutConfiguration {
        WorkoutConfiguration(
            warmUp: warmUp.clamped(to: Self.warmUpRange).rounded(),
            interval: interval.clamped(to: Self.intervalRange).rounded(),
            recovery: recovery.clamped(to: Self.recoveryRange).rounded(),
            intervalCount: min(max(intervalCount, Self.intervalCountRange.lowerBound), Self.intervalCountRange.upperBound),
            coolDown: coolDown.clamped(to: Self.coolDownRange).rounded()
        )
    }

    public func makePlan() -> WorkoutPlan {
        let config = sanitized()
        var phases: [PhaseDefinition] = []
        func add(_ kind: PhaseKind, _ number: Int, _ duration: TimeInterval, final: Bool = false) {
            phases.append(PhaseDefinition(id: phases.count, kind: kind, number: number, duration: duration, isFinalInterval: final))
        }
        if config.warmUp > 0 { add(.warmUp, 0, config.warmUp) }
        for n in 1...config.intervalCount {
            add(.interval, n, config.interval, final: n == config.intervalCount)
            if n < config.intervalCount { add(.recovery, n, config.recovery) }
        }
        if config.coolDown > 0 { add(.coolDown, 0, config.coolDown) }
        return WorkoutPlan(phases: phases)
    }
}

public struct WorkoutPlan: Codable, Equatable, Sendable {
    public let phases: [PhaseDefinition]
    public let totalDuration: TimeInterval
    private let starts: [TimeInterval]

    public init(phases: [PhaseDefinition]) {
        self.phases = phases
        var offset: TimeInterval = 0
        var starts: [TimeInterval] = []
        for phase in phases {
            starts.append(offset)
            offset += phase.duration
        }
        self.starts = starts
        self.totalDuration = offset
    }

    private enum CodingKeys: String, CodingKey { case phases }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(phases: try container.decode([PhaseDefinition].self, forKey: .phases))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phases, forKey: .phases)
    }

    public static let standard = WorkoutConfiguration.standard.makePlan()

    public func startOffset(ofPhase index: Int) -> TimeInterval { starts[index] }
    public func endOffset(ofPhase index: Int) -> TimeInterval { starts[index] + phases[index].duration }

    /// Index of the phase containing timeline `position`, or nil once the
    /// position is at or past the end of the workout.
    public func phaseIndex(at position: TimeInterval) -> Int? {
        guard position < totalDuration, !phases.isEmpty else { return nil }
        let p = max(0, position)
        // Phases are few; a linear scan is clear and fast enough.
        for index in phases.indices where p < endOffset(ofPhase: index) {
            return index
        }
        return nil
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
