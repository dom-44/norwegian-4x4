import XCTest
@testable import FourByFourCore

final class WorkoutPlanTests: XCTestCase {
    func testStandardProtocolIsFortyMinutes() {
        XCTAssertEqual(WorkoutPlan.standard.totalDuration, 40 * 60)
    }

    func testStandardPhaseOrderAndDurations() {
        let phases = WorkoutPlan.standard.phases
        XCTAssertEqual(phases.map(\.kind), [.warmUp, .interval, .recovery, .interval, .recovery, .interval, .recovery, .interval, .coolDown])
        XCTAssertEqual(phases.map(\.duration), [600, 240, 180, 240, 180, 240, 180, 240, 300])
        XCTAssertEqual(phases.map(\.name), ["Warm-up", "Interval 1", "Recovery 1", "Interval 2", "Recovery 2", "Interval 3", "Recovery 3", "Interval 4", "Cool-down"])
        XCTAssertEqual(phases.map(\.id), Array(0..<9))
        XCTAssertEqual(phases.filter(\.isFinalInterval).map(\.number), [4])
    }

    func testPhaseBoundaries() {
        let plan = WorkoutPlan.standard
        XCTAssertEqual(plan.phaseIndex(at: 0), 0)
        XCTAssertEqual(plan.phaseIndex(at: 599.999), 0)
        XCTAssertEqual(plan.phaseIndex(at: 600), 1)
        XCTAssertEqual(plan.phaseIndex(at: 840), 2)
        XCTAssertEqual(plan.phaseIndex(at: 2_099), 7)
        XCTAssertEqual(plan.phaseIndex(at: 2_100), 8)
        XCTAssertEqual(plan.phaseIndex(at: 2_399.9), 8)
        XCTAssertNil(plan.phaseIndex(at: 2_400))
        XCTAssertEqual(plan.startOffset(ofPhase: 8), 2_100)
        XCTAssertEqual(plan.endOffset(ofPhase: 8), 2_400)
    }

    func testCustomConfigurationAndRestoreStandard() {
        var config = WorkoutConfiguration.standard
        config.warmUp = 0
        config.intervalCount = 2
        config.interval = 120
        let plan = config.makePlan()
        XCTAssertEqual(plan.phases.map(\.kind), [.interval, .recovery, .interval, .coolDown])
        XCTAssertEqual(plan.totalDuration, 120 + 180 + 120 + 300)
        XCTAssertFalse(config.isStandard)
        config = .standard
        XCTAssertTrue(config.isStandard)
    }

    func testConfigurationIsClamped() {
        let config = WorkoutConfiguration(warmUp: -5, interval: 5, recovery: 10_000, intervalCount: 50, coolDown: 12.4).sanitized()
        XCTAssertEqual(config.warmUp, 0)
        XCTAssertEqual(config.interval, 30)
        XCTAssertEqual(config.recovery, 900)
        XCTAssertEqual(config.intervalCount, 8)
        XCTAssertEqual(config.coolDown, 12)
    }

    func testPlanCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(WorkoutPlan.standard)
        let decoded = try JSONDecoder().decode(WorkoutPlan.self, from: data)
        XCTAssertEqual(decoded, WorkoutPlan.standard)
        XCTAssertEqual(decoded.totalDuration, 2_400)
    }
}
