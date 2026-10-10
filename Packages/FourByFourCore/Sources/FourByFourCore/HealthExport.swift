import Foundation

// Pure logic for saving finished workouts to Apple Health. The HealthKit
// calls live in the app target (HealthExporter).

/// Workout type shown in Health / Fitness.
public enum HealthActivity: String, Codable, CaseIterable, Sendable, Identifiable {
    case intervalTraining, running, cycling, rowing, elliptical, stairClimbing, walking, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .intervalTraining: return "Interval training (HIIT)"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        case .stairClimbing: return "Stair climbing"
        case .walking: return "Walking (incline)"
        case .other: return "Other"
        }
    }
}

public struct HealthSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var activity: HealthActivity

    public init(enabled: Bool = false, activity: HealthActivity = .intervalTraining) {
        self.enabled = enabled
        self.activity = activity
    }
}

public enum HealthSex: Sendable { case female, male }

public struct HeartRatePoint: Equatable, Sendable {
    public var date: Date
    public var bpm: Int
}

public enum HealthExport {
    /// Heart rate is written at most every this many seconds (Apple Watch
    /// workouts use a similar density; one sample per BLE packet is overkill).
    public static let heartRateInterval: TimeInterval = 5

    /// Heart-rate points for Health. Samples carry active time (pauses
    /// excluded), so dates are `startedAt + t`, clamped to the workout end.
    public static func heartRatePoints(for record: WorkoutRecord, every interval: TimeInterval = heartRateInterval) -> [HeartRatePoint] {
        var points: [HeartRatePoint] = []
        var lastT = -Double.infinity
        for sample in record.samples.sorted(by: { $0.t < $1.t }) where sample.bpm > 0 && sample.t - lastT >= interval {
            lastT = sample.t
            let date = min(record.startedAt.addingTimeInterval(sample.t), record.endedAt)
            points.append(HeartRatePoint(date: date, bpm: sample.bpm))
        }
        return points
    }

    /// Longest gap between two readings that is still counted for energy;
    /// beyond that the sensor was off and nothing is estimated.
    public static let maxEnergyGap: TimeInterval = 15

    /// Active energy in kcal from heart rate, Keytel et al. (2005), the usual
    /// estimate for chest-strap data. Needs weight, age and sex; returns nil
    /// without them or without enough heart-rate data.
    public static func activeEnergy(samples: [HeartRateSample], weightKg: Double?, age: Int?, sex: HealthSex?) -> Double? {
        guard let weightKg, let age, let sex, weightKg > 20, age > 0 else { return nil }
        let sorted = samples.filter { $0.bpm > 0 }.sorted { $0.t < $1.t }
        guard sorted.count >= 2 else { return nil }
        var kcal = 0.0
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let dt = b.t - a.t
            guard dt > 0, dt <= maxEnergyGap else { continue }
            let hr = Double(a.bpm + b.bpm) / 2
            kcal += max(0, kcalPerMinute(heartRate: hr, weightKg: weightKg, age: Double(age), sex: sex)) * dt / 60
        }
        return kcal > 0 ? kcal : nil
    }

    static func kcalPerMinute(heartRate hr: Double, weightKg w: Double, age a: Double, sex: HealthSex) -> Double {
        let kJ: Double
        switch sex {
        case .male: kJ = -55.0969 + 0.6309 * hr + 0.1988 * w + 0.2017 * a
        case .female: kJ = -20.4022 + 0.4472 * hr - 0.1263 * w + 0.074 * a
        }
        return kJ / 4.184
    }
}
