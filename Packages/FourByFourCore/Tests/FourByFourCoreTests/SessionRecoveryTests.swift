import XCTest
@testable import FourByFourCore

/// Background/foreground recovery and recovery after simulated termination.
final class SessionRecoveryTests: XCTestCase {
    var clock: ManualTimeSource!
    var directory: URL!
    var store: ActiveSessionStore!

    override func setUpWithError() throws {
        clock = ManualTimeSource()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ActiveSessionStore(store: JSONFileStore(directory: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeRunningSession() -> WorkoutSession {
        let session = WorkoutSession(plan: .standard, maxHeartRate: 190, sensorName: "Polar H10 TEST", time: clock, store: store, preparationDuration: 5)
        _ = session.start()
        clock.advance(5)
        _ = session.tick()
        XCTAssertEqual(session.status, .running)
        return session
    }

    func testBackgroundGapReconstructsPhaseWithoutReplayingMissedCues() {
        let session = makeRunningSession()
        clock.advance(30)
        _ = session.tick()

        // App suspended for 13 minutes: no ticks at all.
        clock.advance(13 * 60)
        let events = session.tick()

        // 30 s + 780 s = 810 s -> Interval 1 (600..840), 210 s in, 30 s remaining.
        let progress = session.progress()
        XCTAssertEqual(progress.phaseIndex, 1)
        XCTAssertEqual(progress.phaseRemaining, 30, accuracy: 0.0001)
        XCTAssertEqual(events.filter { if case .phaseChanged = $0 { return true } else { return false } }.count, 1)
        // Only a single catch-up announcement; the midpoint and warm-up countdown are not replayed.
        let cues = events.compactMap { event -> WorkoutCue? in if case let .cue(c) = event { return c } else { return nil } }
        XCTAssertEqual(cues, [WorkoutCue(phaseIndex: 1, kind: .phaseStart(late: true))])

        // Returning to the foreground again produces nothing new.
        XCTAssertTrue(session.tick().isEmpty)
    }

    func testPhasesPassedWhileSuspendedAreReportedAsSkipped() {
        let session = makeRunningSession()
        clock.advance(600 + 240 + 180 + 10) // into Interval 2
        let events = session.tick()
        XCTAssertTrue(events.contains(.phaseChanged(from: 0, to: 3, skipped: [1, 2])))
        XCTAssertEqual(session.snapshot.skippedPhases, [1, 2])
    }

    func testRecoveryAfterTerminationRestoresPhaseAndRemainingTime() throws {
        var session: WorkoutSession? = makeRunningSession()
        clock.advance(700)
        _ = session!.tick()
        for _ in 0..<20 { session!.record(bpm: 150); clock.advance(1) }
        session!.persist(force: true)
        let firedBefore = session!.snapshot.firedCues
        session = nil // process killed

        clock.advance(60) // relaunched a minute later, same boot
        let restored = try XCTUnwrap(WorkoutSession(restoringFrom: store, time: clock))
        XCTAssertTrue(restored.wasRestored)
        XCTAssertEqual(restored.samples.count, 20)
        XCTAssertEqual(restored.snapshot.firedCues, firedBefore)
        let events = restored.tick()
        // 700 + 20 + 60 = 780 s: still Interval 1, so no transition is repeated.
        XCTAssertFalse(events.contains { if case .phaseChanged = $0 { return true } else { return false } })
        XCTAssertFalse(events.contains(.cue(WorkoutCue(phaseIndex: 1, kind: .phaseStart(late: false)))))
        XCTAssertEqual(restored.progress().phaseIndex, 1)
        XCTAssertEqual(restored.progress().phaseRemaining, 60, accuracy: 0.0001)
    }

    func testRecoveryAcrossRebootFallsBackToWallClock() throws {
        var session: WorkoutSession? = makeRunningSession()
        clock.advance(100)
        _ = session!.tick()
        session = nil
        clock.reboot(after: 200, newBootID: "boot-2")
        let restored = try XCTUnwrap(WorkoutSession(restoringFrom: store, time: clock))
        _ = restored.tick()
        XCTAssertEqual(restored.progress().activeElapsed, 300, accuracy: 0.0001)
    }

    func testPausedSessionStaysPausedAfterRestore() throws {
        var session: WorkoutSession? = makeRunningSession()
        clock.advance(120)
        _ = session!.pause()
        session = nil
        clock.advance(3_600)
        let restored = try XCTUnwrap(WorkoutSession(restoringFrom: store, time: clock))
        XCTAssertTrue(restored.tick().isEmpty)
        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.progress().activeElapsed, 120, accuracy: 0.0001)
    }

    func testSessionThatEndedWhileTerminatedCompletesOnRestore() throws {
        var session: WorkoutSession? = makeRunningSession()
        clock.advance(10)
        _ = session!.tick()
        session = nil
        clock.advance(5_000)
        let restored = try XCTUnwrap(WorkoutSession(restoringFrom: store, time: clock))
        let events = restored.tick()
        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(restored.progress().activeElapsed, 2_400, accuracy: 0.0001)
        XCTAssertNil(store.load(), "finished sessions are removed from the active-session file")
        XCTAssertNotNil(restored.makeRecord())
    }

    func testFinishedOrMissingSessionIsNotRestored() {
        XCTAssertNil(WorkoutSession(restoringFrom: store, time: clock))
        let session = makeRunningSession()
        _ = session.cancel()
        XCTAssertNil(WorkoutSession(restoringFrom: store, time: clock))
    }

    func testSamplesOnlyRecordedWhileRunning() {
        let session = WorkoutSession(plan: .standard, maxHeartRate: 190, sensorName: nil, time: clock, store: nil, preparationDuration: 5)
        XCTAssertNil(session.record(bpm: 100))
        _ = session.start()
        XCTAssertNil(session.record(bpm: 100), "preparation is not workout time")
        clock.advance(5)
        _ = session.tick()
        clock.advance(1)
        let sample = session.record(bpm: 101)
        XCTAssertEqual(sample?.t ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(sample?.phaseIndex, 0)
        _ = session.pause()
        XCTAssertNil(session.record(bpm: 102))
        XCTAssertNil(session.record(bpm: 0))
        XCTAssertEqual(session.samples.count, 1)
    }

    func testRestartWorkoutClearsSamples() {
        let session = makeRunningSession()
        session.record(bpm: 120)
        _ = session.restartWorkout()
        XCTAssertTrue(session.samples.isEmpty)
        XCTAssertEqual(session.status, .preparing)
    }
}
