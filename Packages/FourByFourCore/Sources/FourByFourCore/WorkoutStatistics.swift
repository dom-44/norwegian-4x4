import Foundation

/// One heart-rate reading recorded during a workout.
public struct HeartRateSample: Codable, Equatable, Sendable {
    /// Active workout time (pauses excluded) when the reading arrived, seconds.
    public var t: TimeInterval
    public var phaseIndex: Int
    /// Seconds since the start of the phase on the workout timeline.
    public var phaseOffset: TimeInterval
    public var bpm: Int

    public init(t: TimeInterval, phaseIndex: Int, phaseOffset: TimeInterval, bpm: Int) {
        self.t = t
        self.phaseIndex = phaseIndex
        self.phaseOffset = phaseOffset
        self.bpm = bpm
    }
}

public struct DataGap: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var duration: TimeInterval { end - start }
}

public struct PhaseSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { phaseIndex }
    public var phaseIndex: Int
    public var kind: PhaseKind
    public var name: String
    public var target: BPMRange?
    public var averageBPM: Int?
    public var maxBPM: Int?
    public var minBPM: Int?
    public var timeInTarget: TimeInterval
    public var timeAbove: TimeInterval
    public var timeBelow: TimeInterval
    /// Seconds of the phase covered by valid readings.
    public var coverage: TimeInterval
    /// Intervals: seconds from phase start until the target zone was first reached.
    public var timeToTarget: TimeInterval?
    /// Recoveries: bpm drop from the phase start to 60 s into the phase.
    public var recoveryDrop60s: Int?
    public var skipped: Bool
}

public struct WorkoutSummary: Codable, Equatable, Sendable {
    public var activeDuration: TimeInterval
    public var averageBPM: Int?
    public var maxBPM: Int?
    /// Time inside the target range across all phases that have a target.
    public var timeInTarget: TimeInterval
    /// Total duration of phases that have a target (denominator for %).
    public var targetPhaseDuration: TimeInterval
    public var phases: [PhaseSummary]
    public var gaps: [DataGap]
    public var sampleCount: Int

    public var timeInTargetFraction: Double {
        targetPhaseDuration > 0 ? min(1, timeInTarget / targetPhaseDuration) : 0
    }
    public var totalGapDuration: TimeInterval { gaps.reduce(0) { $0 + $1.duration } }

    /// Interval phases only.
    public var intervals: [PhaseSummary] { phases.filter { $0.kind == .interval } }
}

public enum WorkoutStatistics {
    /// A reading represents at most this many seconds when weighting time
    /// in zone; longer spaces between readings are treated as gaps.
    public static let maxSampleWeight: TimeInterval = 5
    public static let gapThreshold: TimeInterval = 5

    public static func summarize(samples: [HeartRateSample], plan: WorkoutPlan, maxHR: Int, activeDuration: TimeInterval, skippedPhases: [Int] = []) -> WorkoutSummary {
        let sorted = samples.sorted { $0.t < $1.t }
        var weights: [TimeInterval] = []
        for (i, sample) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1].t : min(sample.t + 1, activeDuration)
            weights.append(min(max(0, next - sample.t), maxSampleWeight))
        }

        var phases: [PhaseSummary] = []
        var totalInTarget: TimeInterval = 0
        var targetDuration: TimeInterval = 0

        for phase in plan.phases {
            let target = HeartRateZones.target(for: phase.kind, maxHR: maxHR)
            let indices = sorted.indices.filter { sorted[$0].phaseIndex == phase.id }
            let bpms = indices.map { sorted[$0].bpm }
            var inTarget: TimeInterval = 0, above: TimeInterval = 0, below: TimeInterval = 0, coverage: TimeInterval = 0
            var timeToTarget: TimeInterval?
            for i in indices {
                let w = weights[i]
                coverage += w
                switch HeartRateZones.status(bpm: sorted[i].bpm, target: target) {
                case .within:
                    inTarget += w
                    if timeToTarget == nil { timeToTarget = sorted[i].phaseOffset }
                case .above:
                    above += w
                    if timeToTarget == nil { timeToTarget = sorted[i].phaseOffset }
                case .below: below += w
                default: break
                }
            }
            var drop: Int?
            if phase.kind == .recovery, phase.duration >= 60,
               let first = indices.first.map({ sorted[$0] }), first.phaseOffset <= 5,
               let at60 = indices.map({ sorted[$0] }).first(where: { $0.phaseOffset >= 60 }), at60.phaseOffset <= 65 {
                drop = first.bpm - at60.bpm
            }
            if target != nil {
                totalInTarget += inTarget
                targetDuration += phase.duration
            }
            phases.append(PhaseSummary(
                phaseIndex: phase.id,
                kind: phase.kind,
                name: phase.name,
                target: target,
                averageBPM: average(bpms),
                maxBPM: bpms.max(),
                minBPM: bpms.min(),
                timeInTarget: inTarget,
                timeAbove: above,
                timeBelow: below,
                coverage: min(coverage, phase.duration),
                timeToTarget: phase.kind == .interval ? timeToTarget : nil,
                recoveryDrop60s: drop,
                skipped: skippedPhases.contains(phase.id)
            ))
        }

        return WorkoutSummary(
            activeDuration: activeDuration,
            averageBPM: average(sorted.map(\.bpm)),
            maxBPM: sorted.map(\.bpm).max(),
            timeInTarget: totalInTarget,
            targetPhaseDuration: targetDuration,
            phases: phases,
            gaps: gaps(in: sorted, activeDuration: activeDuration),
            sampleCount: sorted.count
        )
    }

    /// Periods without readings longer than `gapThreshold`, including at the
    /// start and end of the workout.
    public static func gaps(in sorted: [HeartRateSample], activeDuration: TimeInterval) -> [DataGap] {
        guard activeDuration > 0 else { return [] }
        var result: [DataGap] = []
        var previous: TimeInterval = 0
        for sample in sorted {
            if sample.t - previous > gapThreshold {
                result.append(DataGap(start: previous, end: sample.t))
            }
            previous = max(previous, sample.t)
        }
        if activeDuration - previous > gapThreshold {
            result.append(DataGap(start: previous, end: activeDuration))
        }
        return result
    }

    static func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    /// Reduces a sample list for charting by averaging into fixed buckets.
    public static func downsample(_ samples: [HeartRateSample], bucket: TimeInterval) -> [HeartRateSample] {
        guard bucket > 0 else { return samples }
        var result: [HeartRateSample] = []
        var current: [HeartRateSample] = []
        var bucketIndex = -1
        func flush() {
            guard let first = current.first, let avg = average(current.map(\.bpm)) else { return }
            result.append(HeartRateSample(t: current.map(\.t).reduce(0, +) / Double(current.count), phaseIndex: first.phaseIndex, phaseOffset: first.phaseOffset, bpm: avg))
        }
        for sample in samples.sorted(by: { $0.t < $1.t }) {
            let b = Int(sample.t / bucket)
            if b != bucketIndex || sample.phaseIndex != current.first?.phaseIndex {
                flush()
                current = []
                bucketIndex = b
            }
            current.append(sample)
        }
        flush()
        return result
    }
}
