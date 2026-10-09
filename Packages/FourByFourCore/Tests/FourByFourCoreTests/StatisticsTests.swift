import XCTest
@testable import FourByFourCore

final class StatisticsTests: XCTestCase {
    // Two-phase plan: 60 s interval, 60 s recovery (maxHR 200 → 170–190, 120–140).
    let plan = WorkoutPlan(phases: [
        PhaseDefinition(id: 0, kind: .interval, number: 1, duration: 60, isFinalInterval: true),
        PhaseDefinition(id: 1, kind: .recovery, number: 1, duration: 60)
    ])

    private func samples(_ range: Range<Int>, phase: Int, phaseStart: Int, bpm: (Int) -> Int) -> [HeartRateSample] {
        range.map { HeartRateSample(t: TimeInterval($0), phaseIndex: phase, phaseOffset: TimeInterval($0 - phaseStart), bpm: bpm($0)) }
    }

    func testAveragesMaxAndTimeInZone() {
        // Interval: 20 s below (160), 40 s within (180). Recovery: 60 s at 130 (within).
        let data = samples(0..<20, phase: 0, phaseStart: 0) { _ in 160 }
            + samples(20..<60, phase: 0, phaseStart: 0) { _ in 180 }
            + samples(60..<120, phase: 1, phaseStart: 60) { _ in 130 }
        let summary = WorkoutStatistics.summarize(samples: data, plan: plan, maxHR: 200, activeDuration: 120)
        XCTAssertEqual(summary.maxBPM, 180)
        XCTAssertEqual(summary.phases[0].averageBPM, 173) // (160×20 + 180×40) / 60
        XCTAssertEqual(summary.phases[0].timeInTarget, 40, accuracy: 0.001)
        XCTAssertEqual(summary.phases[0].timeBelow, 20, accuracy: 0.001)
        XCTAssertEqual(summary.phases[0].timeToTarget, 20)
        XCTAssertEqual(summary.phases[1].timeInTarget, 60, accuracy: 0.001)
        XCTAssertEqual(summary.timeInTarget, 100, accuracy: 0.001)
        XCTAssertEqual(summary.targetPhaseDuration, 120)
        XCTAssertTrue(summary.gaps.isEmpty)
    }

    func testGapsAreDetectedAndNotCountedAsTimeInZone() {
        // Sensor lost from 10 s to 40 s.
        let data = samples(0..<10, phase: 0, phaseStart: 0) { _ in 180 }
            + samples(40..<60, phase: 0, phaseStart: 0) { _ in 180 }
        let summary = WorkoutStatistics.summarize(samples: data, plan: plan, maxHR: 200, activeDuration: 120)
        XCTAssertEqual(summary.gaps.count, 2)
        XCTAssertEqual(summary.gaps[0].start, 9)
        XCTAssertEqual(summary.gaps[0].end, 40)
        XCTAssertEqual(summary.gaps[1].start, 59)
        XCTAssertEqual(summary.gaps[1].end, 120)
        // 9 samples × 1 s + 1 sample capped at 5 s + 19 × 1 s + last 1 s = 34 s
        XCTAssertEqual(summary.phases[0].timeInTarget, 34, accuracy: 0.001)
        XCTAssertNil(summary.phases[1].averageBPM)
    }

    func testRecoveryDrop() {
        let data = samples(60..<120, phase: 1, phaseStart: 60) { 175 - ($0 - 60) / 2 }
        let summary = WorkoutStatistics.summarize(samples: data, plan: plan, maxHR: 200, activeDuration: 120)
        // 175 at offset 0, last sample at offset 59 — no reading at ≥ 60 s within the 60 s phase.
        XCTAssertNil(summary.phases[1].recoveryDrop60s)

        let longPlan = WorkoutPlan(phases: [PhaseDefinition(id: 0, kind: .recovery, number: 1, duration: 180)])
        let rec = (0..<180).map { HeartRateSample(t: TimeInterval($0), phaseIndex: 0, phaseOffset: TimeInterval($0), bpm: 175 - $0 / 2) }
        let s2 = WorkoutStatistics.summarize(samples: rec, plan: longPlan, maxHR: 200, activeDuration: 180)
        XCTAssertEqual(s2.phases[0].recoveryDrop60s, 30)
    }

    func testNoSamples() {
        let summary = WorkoutStatistics.summarize(samples: [], plan: plan, maxHR: 200, activeDuration: 120)
        XCTAssertNil(summary.averageBPM)
        XCTAssertEqual(summary.timeInTarget, 0)
        XCTAssertEqual(summary.gaps, [DataGap(start: 0, end: 120)])
    }

    func testDownsample() {
        let data = samples(0..<60, phase: 0, phaseStart: 0) { $0 < 30 ? 100 : 200 }
        let reduced = WorkoutStatistics.downsample(data, bucket: 30)
        XCTAssertEqual(reduced.map(\.bpm), [100, 200])
    }

    func testHistoryTrend() {
        let base = Date(timeIntervalSince1970: 0)
        let overviews = (0..<6).map { i in
            WorkoutOverview(id: UUID(), startedAt: base.addingTimeInterval(Double(i) * 86_400), completed: true,
                            activeDuration: 2_400, averageBPM: 150, maxBPM: 180, timeInTarget: 600,
                            timeInTargetFraction: 0.5, intervalAverageBPM: 160 + i)
        }
        let trend = HistoryTrend.compute(overviews)
        XCTAssertEqual(trend.workoutCount, 6)
        XCTAssertEqual(trend.averageTimeInTargetFraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(trend.intervalBPMChange, 3) // (165+164+163)/3 − (162+161+160)/3
    }
}
