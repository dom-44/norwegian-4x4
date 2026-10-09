import Foundation

/// The user's maximum heart rate, entered manually or estimated from age.
public struct HeartRateProfile: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case manual, ageEstimate }

    public var maxHeartRate: Int
    public var source: Source
    public var age: Int?

    public init(maxHeartRate: Int, source: Source, age: Int? = nil) {
        self.maxHeartRate = maxHeartRate
        self.source = source
        self.age = age
    }

    public static let validMaxRange = 120...230
    public static let validAgeRange = 10...100
    public static let `default` = HeartRateProfile(maxHeartRate: 185, source: .manual)

    /// Classic population estimate HRmax = 220 − age. Individual values commonly
    /// differ by ±10–20 bpm, so the UI labels this as an estimate.
    public static func estimatedMax(age: Int) -> Int {
        220 - min(max(age, validAgeRange.lowerBound), validAgeRange.upperBound)
    }

    public static func estimated(age: Int) -> HeartRateProfile {
        HeartRateProfile(maxHeartRate: estimatedMax(age: age), source: .ageEstimate, age: age)
    }

    public var sanitizedMax: Int {
        min(max(maxHeartRate, Self.validMaxRange.lowerBound), Self.validMaxRange.upperBound)
    }
}

public struct BPMRange: Codable, Equatable, Sendable {
    public var lower: Int
    public var upper: Int

    public init(lower: Int, upper: Int) {
        self.lower = lower
        self.upper = upper
    }

    public func contains(_ bpm: Int) -> Bool { bpm >= lower && bpm <= upper }

    public var label: String { "\(lower)–\(upper)" }
}

public enum ZoneStatus: String, Codable, Sendable {
    case below, within, above
    /// No live heart rate (no sensor, stale reading, lost skin contact).
    case unavailable
    /// The phase has no target range (warm-up, cool-down).
    case noTarget
}

/// Single source of truth for target calculation.
///
/// Rounding rule (used everywhere): each bound is `percent × HRmax / 100`
/// rounded to the nearest whole bpm with halves rounding up (computed in
/// integer arithmetic, so there is no floating-point ambiguity). A reading is
/// in-zone when `lower ≤ bpm ≤ upper` using those rounded bounds.
public enum HeartRateZones {
    /// Percent of HRmax.
    public static let highIntensity: ClosedRange<Int> = 85...95
    public static let recovery: ClosedRange<Int> = 60...70

    public static func bpm(percent: Int, of maxHR: Int) -> Int {
        (maxHR * percent * 2 + 100) / 200
    }

    public static func range(_ percents: ClosedRange<Int>, maxHR: Int) -> BPMRange {
        BPMRange(lower: bpm(percent: percents.lowerBound, of: maxHR), upper: bpm(percent: percents.upperBound, of: maxHR))
    }

    public static func percents(for kind: PhaseKind) -> ClosedRange<Int>? {
        switch kind {
        case .interval: return highIntensity
        case .recovery: return recovery
        case .warmUp, .coolDown: return nil
        }
    }

    public static func target(for kind: PhaseKind, maxHR: Int) -> BPMRange? {
        percents(for: kind).map { range($0, maxHR: maxHR) }
    }

    public static func status(bpm: Int?, target: BPMRange?) -> ZoneStatus {
        guard let bpm else { return .unavailable }
        guard let target else { return .noTarget }
        if bpm < target.lower { return .below }
        if bpm > target.upper { return .above }
        return .within
    }

    /// Percentage of HRmax, rounded to a whole percent.
    public static func percentOfMax(bpm: Int, maxHR: Int) -> Int {
        guard maxHR > 0 else { return 0 }
        return Int((Double(bpm) / Double(maxHR) * 100).rounded())
    }
}

/// Decides whether the most recent reading may be shown as *current*.
public struct HeartRateSignal: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case live(bpm: Int)
        /// A reading exists but is too old to be shown as current.
        case stale(lastBPM: Int, age: TimeInterval)
        case noContact
        case unavailable
    }

    /// Polar H10 notifies roughly once per second; 5 s without a packet means
    /// the value must no longer be presented as current.
    public static let staleAfter: TimeInterval = 5

    public static func evaluate(lastBPM: Int?, lastReceived: Timestamp?, contact: SensorContact?, now: Timestamp) -> State {
        guard let lastBPM, let lastReceived else { return .unavailable }
        let age = lastReceived.seconds(until: now)
        if age > staleAfter || age < -1 { return .stale(lastBPM: lastBPM, age: max(age, 0)) }
        if contact == .notDetected { return .noContact }
        return .live(bpm: lastBPM)
    }
}

public extension HeartRateSignal.State {
    var liveBPM: Int? {
        if case let .live(bpm) = self { return bpm }
        return nil
    }
}
