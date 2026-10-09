import XCTest
@testable import FourByFourCore

final class CoachingTests: XCTestCase {
    let plan = WorkoutPlan.standard
    let settings = CoachingSettings()

    func testPhaseStartLines() {
        XCTAssertEqual(CoachingScript.startLine(phase: plan.phases[0], maxHR: 200), "Warm-up. Start easy and gradually increase your pace.")
        XCTAssertEqual(CoachingScript.startLine(phase: plan.phases[1], maxHR: 200), "First interval. Increase your intensity. Target 170 to 190.")
        XCTAssertEqual(CoachingScript.startLine(phase: plan.phases[2], maxHR: 200), "Recovery. Reduce intensity but keep moving.")
        XCTAssertEqual(CoachingScript.startLine(phase: plan.phases[7], maxHR: 200), "Final interval. Maintain your effort. Target 170 to 190.")
        XCTAssertEqual(CoachingScript.startLine(phase: plan.phases[8], maxHR: 200), "Cool-down. Gradually reduce your pace.")
    }

    func testLateStartIsShortCatchUpWithoutTone() {
        let action = CoachingScript.action(for: WorkoutCue(phaseIndex: 2, kind: .phaseStart(late: true)), plan: plan, maxHR: 200, currentBPM: nil, remaining: 90, settings: settings)
        XCTAssertEqual(action.speech, "Recovery 1. 1 and a half minutes remaining.")
        XCTAssertNil(action.sound)
    }

    func testMidpointNudgesTowardTarget() {
        let cue = WorkoutCue(phaseIndex: 1, kind: .midpoint)
        let below = CoachingScript.action(for: cue, plan: plan, maxHR: 200, currentBPM: 150, remaining: 120, settings: settings)
        XCTAssertEqual(below.speech, "Halfway. Move toward your target heart rate.")
        let unknown = CoachingScript.action(for: cue, plan: plan, maxHR: 200, currentBPM: nil, remaining: 120, settings: settings)
        XCTAssertEqual(unknown.speech, "Halfway. Hold your effort.")
    }

    func testSettingsDisableOutput() {
        var quiet = CoachingSettings()
        quiet.voiceEnabled = false
        quiet.transitionSounds = false
        quiet.haptics = false
        let action = CoachingScript.action(for: WorkoutCue(phaseIndex: 1, kind: .phaseStart(late: false)), plan: plan, maxHR: 200, currentBPM: nil, remaining: 240, settings: quiet)
        XCTAssertTrue(action.isEmpty)
    }

    func testCountdown() {
        let ten = CoachingScript.action(for: WorkoutCue(phaseIndex: 1, kind: .countdown(10)), plan: plan, maxHR: 200, currentBPM: nil, remaining: 10, settings: settings)
        XCTAssertEqual(ten.speech, "Ten seconds.")
        let three = CoachingScript.action(for: WorkoutCue(phaseIndex: 1, kind: .countdown(3)), plan: plan, maxHR: 200, currentBPM: nil, remaining: 3, settings: settings)
        XCTAssertNil(three.speech)
        XCTAssertEqual(three.sound, .countdownTick)
    }

    func testSpokenDuration() {
        XCTAssertEqual(CoachingScript.spokenDuration(45), "45 seconds")
        XCTAssertEqual(CoachingScript.spokenDuration(60), "1 minute")
        XCTAssertEqual(CoachingScript.spokenDuration(150), "2 and a half minutes")
        XCTAssertEqual(CoachingScript.spokenDuration(130), "2 minutes 10 seconds")
    }
}

final class PersistenceTests: XCTestCase {
    var directory: URL!
    var files: JSONFileStore!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = JSONFileStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSettingsRoundTripAndReset() {
        let store = SettingsStore(store: files)
        var settings = store.load()
        XCTAssertEqual(settings, AppSettings())
        settings.heartRate = .estimated(age: 30)
        settings.music.provider = .spotify
        settings.music[.highIntensity] = MusicSelection(title: "Go", uri: "spotify:playlist:1")
        settings.preferredSensor = SensorPreference(identifier: UUID(), name: "Polar H10 1234")
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        store.reset()
        XCTAssertEqual(store.load(), AppSettings())
    }

    func testCorruptSettingsFallBackToDefaults() throws {
        try Data("not json".utf8).write(to: files.url(for: "settings.json"))
        XCTAssertEqual(SettingsStore(store: files).load(), AppSettings())
    }

    func testHistorySaveListDelete() throws {
        let history = HistoryStore(store: files)
        let clock = ManualTimeSource()
        let session = WorkoutSession(plan: .standard, maxHeartRate: 190, sensorName: nil, time: clock, store: nil, preparationDuration: 0)
        _ = session.start()
        for _ in 0..<30 { clock.advance(1); session.record(bpm: 120) }
        _ = session.cancel()
        let record = try XCTUnwrap(session.makeRecord())
        XCTAssertFalse(record.completed)
        try history.save(record)
        XCTAssertEqual(history.overviews().map(\.id), [record.id])
        XCTAssertEqual(history.record(id: record.id), record)
        history.delete(id: record.id)
        XCTAssertTrue(history.overviews().isEmpty)
        XCTAssertNil(history.record(id: record.id))

        try history.save(record)
        history.deleteAll()
        XCTAssertTrue(history.overviews().isEmpty)
    }
}
