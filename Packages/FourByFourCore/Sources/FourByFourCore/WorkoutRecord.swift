import Foundation

/// A finished (completed or ended early) workout stored in history.
public struct WorkoutRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var completed: Bool
    public var plan: WorkoutPlan
    public var maxHeartRate: Int
    public var sensorName: String?
    public var samples: [HeartRateSample]
    public var summary: WorkoutSummary

    public init(id: UUID, startedAt: Date, endedAt: Date, completed: Bool, plan: WorkoutPlan, maxHeartRate: Int, sensorName: String?, samples: [HeartRateSample], summary: WorkoutSummary) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.completed = completed
        self.plan = plan
        self.maxHeartRate = maxHeartRate
        self.sensorName = sensorName
        self.samples = samples
        self.summary = summary
    }

    public var overview: WorkoutOverview {
        WorkoutOverview(id: id, startedAt: startedAt, completed: completed, activeDuration: summary.activeDuration,
                        averageBPM: summary.averageBPM, maxBPM: summary.maxBPM,
                        timeInTarget: summary.timeInTarget, timeInTargetFraction: summary.timeInTargetFraction,
                        intervalAverageBPM: WorkoutStatistics.average(summary.intervals.compactMap(\.averageBPM)))
    }
}

/// Lightweight history index entry (no samples).
public struct WorkoutOverview: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var completed: Bool
    public var activeDuration: TimeInterval
    public var averageBPM: Int?
    public var maxBPM: Int?
    public var timeInTarget: TimeInterval
    public var timeInTargetFraction: Double
    public var intervalAverageBPM: Int?
}

public struct HistoryTrend: Equatable, Sendable {
    public var workoutCount: Int
    public var completedCount: Int
    public var averageTimeInTargetFraction: Double?
    /// Difference between the average interval bpm of the latest three
    /// workouts and the three before, when available.
    public var intervalBPMChange: Int?

    public static func compute(_ overviews: [WorkoutOverview]) -> HistoryTrend {
        let sorted = overviews.sorted { $0.startedAt > $1.startedAt }
        let completed = sorted.filter(\.completed)
        let fractions = completed.map(\.timeInTargetFraction)
        let avgFraction = fractions.isEmpty ? nil : fractions.reduce(0, +) / Double(fractions.count)
        let intervalBPMs = completed.compactMap(\.intervalAverageBPM)
        var change: Int?
        if intervalBPMs.count >= 6,
           let recent = WorkoutStatistics.average(Array(intervalBPMs[0..<3])),
           let prior = WorkoutStatistics.average(Array(intervalBPMs[3..<6])) {
            change = recent - prior
        }
        return HistoryTrend(workoutCount: sorted.count, completedCount: completed.count,
                            averageTimeInTargetFraction: avgFraction, intervalBPMChange: change)
    }
}
