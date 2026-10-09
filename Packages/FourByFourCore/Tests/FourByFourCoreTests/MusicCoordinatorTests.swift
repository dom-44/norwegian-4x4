import XCTest
@testable import FourByFourCore

@MainActor
final class MockMusicProvider: MusicProvider {
    var kind: MusicProviderKind = .spotify
    var capabilities = MusicCapabilities(canSwitchAutomatically: true, requiresForeground: false, canPauseResume: true, canReadPlaybackState: true)
    var failWith: Error?
    var played: [MusicSelection] = []
    var pauseCalls = 0

    func play(_ selection: MusicSelection, appIsActive: Bool) async throws {
        if let failWith { throw failWith }
        played.append(selection)
    }
    func pause() async throws {
        pauseCalls += 1
        if let failWith { throw failWith }
    }
    func resume() async throws {
        if let failWith { throw failWith }
    }
}

@MainActor
final class MusicCoordinatorTests: XCTestCase {
    let hard = MusicSelection(title: "Hard", uri: "spotify:playlist:hard")
    let easy = MusicSelection(title: "Easy", uri: "spotify:playlist:easy")
    var now: TimeInterval = 0

    private func prefs() -> MusicPreferences {
        var p = MusicPreferences(provider: .spotify)
        p.warmUp = easy
        p.highIntensity = hard
        p.recovery = easy
        p.coolDown = easy
        return p
    }

    private func coordinator(_ provider: MockMusicProvider) -> MusicCoordinator {
        MusicCoordinator(provider: provider, preferences: prefs(), clock: { [unowned self] in self.now })
    }

    func testSwitchesPlaylistPerPhase() async {
        let provider = MockMusicProvider()
        let c = coordinator(provider)
        let o1 = await c.phaseDidStart(.warmUp, appIsActive: true)
        XCTAssertEqual(o1, .switched(.warmUp, easy))
        let o2 = await c.phaseDidStart(.interval, appIsActive: false)
        XCTAssertEqual(o2, .switched(.highIntensity, hard))
        XCTAssertEqual(provider.played, [easy, hard])
    }

    func testSamePlaylistIsNotRestarted() async {
        let provider = MockMusicProvider()
        let c = coordinator(provider)
        await c.phaseDidStart(.recovery, appIsActive: true)
        let outcome = await c.phaseDidStart(.coolDown, appIsActive: true)
        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(provider.played, [easy])
    }

    func testFailureFallsBackToManualPromptWithoutThrowing() async {
        let provider = MockMusicProvider()
        provider.failWith = MusicProviderError.notConnected
        let c = coordinator(provider)
        let outcome = await c.phaseDidStart(.interval, appIsActive: true)
        XCTAssertEqual(outcome, .manualPrompt(.highIntensity, hard, reason: .notConnected))
    }

    func testUnknownErrorsAreWrapped() async {
        struct Boom: Error {}
        let provider = MockMusicProvider()
        provider.failWith = Boom()
        let outcome = await coordinator(provider).phaseDidStart(.interval, appIsActive: true)
        guard case .manualPrompt(_, _, reason: .commandFailed?) = outcome else { return XCTFail("\(outcome)") }
    }

    func testBackoffPreventsReconnectStorm() async {
        let provider = MockMusicProvider()
        provider.failWith = MusicProviderError.notConnected
        let c = coordinator(provider)
        await c.phaseDidStart(.interval, appIsActive: true)
        XCTAssertEqual(c.consecutiveFailures, 1)
        now = 10
        provider.failWith = nil
        let blocked = await c.phaseDidStart(.recovery, appIsActive: true)
        XCTAssertEqual(blocked, .manualPrompt(.recovery, easy, reason: .notConnected))
        XCTAssertTrue(provider.played.isEmpty, "no attempt inside the back-off window")
        now = 100
        let ok = await c.phaseDidStart(.interval, appIsActive: true)
        XCTAssertEqual(ok, .switched(.highIntensity, hard))
    }

    func testAutoSwitchSuspendedAfterRepeatedFailures() async {
        let provider = MockMusicProvider()
        provider.failWith = MusicProviderError.notConnected
        let c = coordinator(provider)
        for kind in [PhaseKind.interval, .recovery, .interval] {
            await c.phaseDidStart(kind, appIsActive: true)
            now += 1_000
        }
        XCTAssertTrue(c.autoSwitchSuspended)
        provider.failWith = nil
        let outcome = await c.phaseDidStart(.recovery, appIsActive: true)
        XCTAssertEqual(outcome, .manualPrompt(.recovery, easy, reason: .notConnected))
        XCTAssertTrue(provider.played.isEmpty)
        c.resetSession()
        XCTAssertFalse(c.autoSwitchSuspended)
    }

    func testForegroundOnlyProviderPromptsWhenInBackground() async {
        let provider = MockMusicProvider()
        provider.capabilities.requiresForeground = true
        let c = coordinator(provider)
        let outcome = await c.phaseDidStart(.interval, appIsActive: false)
        XCTAssertEqual(outcome, .manualPrompt(.highIntensity, hard, reason: .requiresForeground))
        XCTAssertTrue(provider.played.isEmpty)
    }

    func testManualModeAlwaysPrompts() async {
        let c = MusicCoordinator(provider: ManualMusicProvider(), preferences: prefs())
        let o1 = await c.phaseDidStart(.interval, appIsActive: false)
        XCTAssertEqual(o1, .manualPrompt(.highIntensity, hard, reason: nil))
        let o2 = await c.phaseDidStart(.interval, appIsActive: false)
        XCTAssertEqual(o2, .nothing, "no duplicate prompt for the same slot")
    }

    func testNoMusicDoesNothing() async {
        let c = MusicCoordinator(provider: NoMusicProvider(), preferences: MusicPreferences())
        let outcome = await c.phaseDidStart(.interval, appIsActive: true)
        XCTAssertEqual(outcome, .nothing)
    }

    func testPauseErrorsAreSwallowed() async {
        let provider = MockMusicProvider()
        provider.failWith = MusicProviderError.notConnected
        let c = coordinator(provider)
        await c.pause()
        XCTAssertEqual(provider.pauseCalls, 1)
    }

    /// The workout engine has no dependency on music: a failing provider
    /// cannot affect the timer. This test documents that by driving both.
    func testMusicFailureDoesNotAffectWorkoutTimer() async {
        let clock = ManualTimeSource()
        let session = WorkoutSession(plan: .standard, maxHeartRate: 190, sensorName: nil, time: clock, store: nil, preparationDuration: 0)
        let provider = MockMusicProvider()
        provider.failWith = MusicProviderError.commandFailed("offline")
        let c = coordinator(provider)
        for event in session.start() {
            if case let .phaseChanged(_, to, _) = event {
                await c.phaseDidStart(session.plan.phases[to].kind, appIsActive: true)
            }
        }
        clock.advance(600)
        let events = session.tick()
        XCTAssertTrue(events.contains(.phaseChanged(from: 0, to: 1, skipped: [])))
        XCTAssertEqual(session.progress().phaseIndex, 1)
    }
}
