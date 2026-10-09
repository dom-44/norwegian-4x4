import XCTest
@testable import FourByFourCore

final class WorkoutEngineTests: XCTestCase {
    var clock: ManualTimeSource!
    var engine: WorkoutEngine!

    override func setUp() {
        clock = ManualTimeSource()
        engine = WorkoutEngine(plan: .standard, createdAt: clock.now().wall, preparationDuration: 5)
    }

    private func advance(_ seconds: TimeInterval) -> [WorkoutEvent] {
        clock.advance(seconds)
        return engine.update(at: clock.now())
    }

    private func phaseChanges(_ events: [WorkoutEvent]) -> [Int] {
        events.compactMap { if case let .phaseChanged(_, to, _) = $0 { return to } else { return nil } }
    }

    private func startRunning() {
        _ = engine.start(at: clock.now())
        _ = advance(5)
        XCTAssertEqual(engine.status, .running)
    }

    func testPreparationThenStart() {
        let events = engine.start(at: clock.now())
        XCTAssertEqual(events, [.preparationStarted])
        XCTAssertEqual(engine.status, .preparing)
        XCTAssertEqual(engine.progress(at: clock.now()).preparationRemaining, 5)
        XCTAssertTrue(advance(4.5).isEmpty)
        let started = advance(0.5)
        XCTAssertEqual(started.first, .workoutStarted)
        XCTAssertEqual(phaseChanges(started), [0])
        XCTAssertTrue(started.contains(.cue(WorkoutCue(phaseIndex: 0, kind: .phaseStart(late: false)))))
        XCTAssertEqual(engine.progress(at: clock.now()).activeElapsed, 0)
    }

    func testPreparationEndUsesExactStartTimeEvenIfObservedLate() {
        _ = engine.start(at: clock.now())
        _ = advance(65) // app suspended during preparation
        let progress = engine.progress(at: clock.now())
        XCTAssertEqual(progress.activeElapsed, 60, accuracy: 0.0001)
        XCTAssertEqual(progress.phaseRemaining, 540, accuracy: 0.0001)
    }

    func testFullWorkoutTransitionsInOrderExactlyOnce() {
        startRunning()
        var changes: [Int] = []
        var completed = 0
        for _ in 0..<(2_400 * 4 + 10) {
            let events = advance(0.25)
            changes += phaseChanges(events)
            completed += events.filter { $0 == .completed }.count
        }
        XCTAssertEqual(changes, Array(1...8))
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(engine.status, .completed)
        XCTAssertEqual(engine.progress(at: clock.now()).activeElapsed, 2_400, accuracy: 0.0001)
        XCTAssertTrue(engine.snapshot.skippedPhases.isEmpty)
    }

    func testExactPhaseTransitionTimes() {
        startRunning()
        XCTAssertTrue(phaseChanges(advance(599.75)).isEmpty)
        XCTAssertEqual(phaseChanges(advance(0.25)), [1])
        XCTAssertTrue(phaseChanges(advance(239.75)).isEmpty)
        XCTAssertEqual(phaseChanges(advance(0.25)), [2])
    }

    func testPauseFreezesWorkoutTime() {
        startRunning()
        _ = advance(100)
        XCTAssertEqual(engine.pause(at: clock.now()).last, .paused)
        XCTAssertEqual(engine.status, .paused)
        _ = advance(1_000)
        let paused = engine.progress(at: clock.now())
        XCTAssertEqual(paused.activeElapsed, 100, accuracy: 0.0001)
        XCTAssertEqual(paused.phaseIndex, 0)
        XCTAssertEqual(paused.phaseRemaining, 500, accuracy: 0.0001)

        XCTAssertEqual(engine.resume(at: clock.now()).first, .resumed)
        _ = advance(50)
        XCTAssertEqual(engine.progress(at: clock.now()).activeElapsed, 150, accuracy: 0.0001)
        XCTAssertEqual(engine.snapshot.pauseCount, 1)
    }

    func testPauseAndResumeAreIgnoredInWrongStates() {
        XCTAssertTrue(engine.pause(at: clock.now()).isEmpty)
        XCTAssertTrue(engine.resume(at: clock.now()).isEmpty)
        startRunning()
        XCTAssertTrue(engine.resume(at: clock.now()).isEmpty)
    }

    func testSkipJumpsToNextPhaseStart() {
        startRunning()
        _ = advance(30)
        let events = engine.skipPhase(at: clock.now())
        XCTAssertEqual(phaseChanges(events), [1])
        let progress = engine.progress(at: clock.now())
        XCTAssertEqual(progress.phaseIndex, 1)
        XCTAssertEqual(progress.phaseElapsed, 0, accuracy: 0.0001)
        XCTAssertEqual(progress.activeElapsed, 30, accuracy: 0.0001, "real training time is not inflated by skipping")
        XCTAssertEqual(progress.timelinePosition, 600, accuracy: 0.0001)
        XCTAssertTrue(engine.snapshot.skippedPhases.isEmpty, "a phase the user saw and skipped is not 'missed'")
    }

    func testSkipWhilePaused() {
        startRunning()
        _ = engine.pause(at: clock.now())
        XCTAssertEqual(phaseChanges(engine.skipPhase(at: clock.now())), [1])
        XCTAssertEqual(engine.status, .paused)
        _ = advance(100)
        XCTAssertEqual(engine.progress(at: clock.now()).phaseElapsed, 0, accuracy: 0.0001)
    }

    func testSkipFromLastPhaseCompletes() {
        startRunning()
        for _ in 0..<8 { _ = engine.skipPhase(at: clock.now()) }
        XCTAssertEqual(engine.progress(at: clock.now()).phaseIndex, 8)
        let events = engine.skipPhase(at: clock.now())
        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(engine.status, .completed)
    }

    func testRestartPhaseRefiresItsCues() {
        startRunning()
        _ = advance(600 + 200) // into interval 1, past midpoint
        let restart = engine.restartPhase(at: clock.now())
        XCTAssertTrue(restart.contains(.phaseRestarted(1)))
        XCTAssertTrue(restart.contains(.cue(WorkoutCue(phaseIndex: 1, kind: .phaseStart(late: false)))))
        XCTAssertTrue(phaseChanges(restart).isEmpty)
        let progress = engine.progress(at: clock.now())
        XCTAssertEqual(progress.phaseIndex, 1)
        XCTAssertEqual(progress.phaseRemaining, 240, accuracy: 0.0001)
        let mid = advance(120)
        XCTAssertTrue(mid.contains(.cue(WorkoutCue(phaseIndex: 1, kind: .midpoint))))
    }

    func testRestartWorkout() {
        startRunning()
        _ = advance(1_000)
        let events = engine.restartWorkout(at: clock.now())
        XCTAssertEqual(events, [.preparationStarted])
        XCTAssertEqual(engine.status, .preparing)
        _ = advance(5)
        let progress = engine.progress(at: clock.now())
        XCTAssertEqual(progress.activeElapsed, 0)
        XCTAssertEqual(progress.phaseIndex, 0)
    }

    func testCancel() {
        startRunning()
        _ = advance(42)
        XCTAssertEqual(engine.cancel(at: clock.now()), [.cancelled])
        XCTAssertEqual(engine.status, .cancelled)
        _ = advance(100)
        XCTAssertEqual(engine.progress(at: clock.now()).activeElapsed, 42, accuracy: 0.0001)
        XCTAssertTrue(engine.cancel(at: clock.now()).isEmpty)
    }

    func testCountdownAndMidpointCues() {
        startRunning()
        var all: [WorkoutCue] = []
        for _ in 0..<(840 * 8) {
            for case let .cue(cue) in advance(0.125) { all.append(cue) }
        }
        // Warm-up has no midpoint reminder but has a final countdown.
        XCTAssertEqual(all.filter { $0.phaseIndex == 0 }.map(\.kind), [.countdown(10), .countdown(3), .countdown(2), .countdown(1)])
        XCTAssertEqual(all.filter { $0.phaseIndex == 1 }.map(\.kind), [.phaseStart(late: false), .midpoint, .countdown(10), .countdown(3), .countdown(2), .countdown(1)])
    }

    func testUpdateIsIdempotent() {
        startRunning()
        _ = advance(600)
        XCTAssertTrue(engine.update(at: clock.now()).isEmpty)
        XCTAssertTrue(engine.update(at: clock.now()).isEmpty)
    }

    func testNoTimeTravelWhenClockGoesBackwards() {
        startRunning()
        _ = advance(100)
        clock.current = clock.current.adding(-50)
        let progress = engine.progress(at: clock.now())
        XCTAssertGreaterThanOrEqual(progress.activeElapsed, 0)
        XCTAssertEqual(progress.phaseIndex, 0)
    }

    func testUpcomingPhaseStartsForBackupAlerts() {
        startRunning()
        _ = advance(100)
        let upcoming = engine.upcomingPhaseStarts(at: clock.now())
        XCTAssertEqual(upcoming.map { $0.phaseIndex }, Array(1...9))
        XCTAssertEqual(upcoming[0].date.timeIntervalSince(clock.now().wall), 500, accuracy: 0.001)
        XCTAssertEqual(upcoming.last!.date.timeIntervalSince(clock.now().wall), 2_300, accuracy: 0.001)
        _ = engine.pause(at: clock.now())
        XCTAssertTrue(engine.upcomingPhaseStarts(at: clock.now()).isEmpty)
    }
}
