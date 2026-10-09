import FourByFourCore
import Foundation
import Observation
import UIKit

/// Runs a workout session on the main actor: drives the timer, routes events
/// to coaching audio / haptics / music / notifications, records heart rate
/// and saves history. All timing lives in `WorkoutEngine`; this class only
/// asks it "what is true now?" whenever something happens.
@Observable
@MainActor
final class WorkoutController {
    private(set) var session: WorkoutSession? = nil
    private(set) var progress: WorkoutProgress? = nil
    private(set) var signal: HeartRateSignal.State = .unavailable
    private(set) var zone: ZoneStatus = .unavailable
    private(set) var target: BPMRange? = nil
    private(set) var finishedRecord: WorkoutRecord? = nil
    private(set) var restoredFromTermination = false
    /// Incremented on each phase change; the UI animates on it.
    private(set) var phaseChangeCount = 0
    private(set) var saveError: String? = nil

    var isActive: Bool { session != nil }
    var status: WorkoutStatus { progress?.status ?? .idle }
    var maxHeartRate: Int { session?.maxHeartRate ?? settings().heartRate.sanitizedMax }

    @ObservationIgnored private let settings: () -> AppSettings
    @ObservationIgnored private let sensor: HeartRateSensorManager
    @ObservationIgnored private let music: MusicCenter
    @ObservationIgnored private let audio: CoachingAudio
    @ObservationIgnored private let notifier = TransitionNotifier()
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let activeStore: ActiveSessionStore
    @ObservationIgnored private let time: TimeSource
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored var onHistoryChanged: (() -> Void)?

    init(settings: @escaping () -> AppSettings, sensor: HeartRateSensorManager, music: MusicCenter, audio: CoachingAudio,
         history: HistoryStore, activeStore: ActiveSessionStore, time: TimeSource = SystemTimeSource.shared) {
        self.settings = settings
        self.sensor = sensor
        self.music = music
        self.audio = audio
        self.history = history
        self.activeStore = activeStore
        self.time = time
    }

    // MARK: Lifecycle

    /// Restores a session that was running when the app was terminated.
    func restoreIfNeeded() {
        guard session == nil, let restored = WorkoutSession(restoringFrom: activeStore, time: time) else { return }
        session = restored
        restoredFromTermination = true
        music.beginSession()
        process(restored.tick())
        startTimer()
        updateIdleTimer()
        refresh()
    }

    func start() {
        guard session == nil else { return }
        let s = settings()
        let newSession = WorkoutSession(plan: s.workout.makePlan(), maxHeartRate: s.heartRate.sanitizedMax,
                                        sensorName: sensor.connectedSensor?.name, time: time, store: activeStore)
        session = newSession
        finishedRecord = nil
        restoredFromTermination = false
        saveError = nil
        audio.speechRate = Float(s.coaching.speechRate)
        music.beginSession()
        if s.coaching.lockScreenAlerts {
            Task { await notifier.requestAuthorizationIfNeeded() }
        }
        process(newSession.start())
        startTimer()
        updateIdleTimer()
        refresh()
    }

    // MARK: Controls

    func togglePause() {
        guard let session else { return }
        switch session.status {
        case .running: process(session.pause())
        case .paused: process(session.resume())
        default: return
        }
        Haptics.tap()
        refresh()
    }

    func skipPhase() {
        guard let session else { return }
        process(session.skipPhase())
        refresh()
    }

    func restartPhase() {
        guard let session else { return }
        process(session.restartPhase())
        refresh()
    }

    func restartWorkout() {
        guard let session else { return }
        audio.stopAll()
        music.beginSession()
        process(session.restartWorkout())
        refresh()
    }

    /// Ends the workout early. `save` stores it in history (if it started).
    func end(save: Bool) {
        guard let session else { return }
        _ = session.cancel()
        finish(session: session, save: save)
    }

    func dismissSummary() {
        finishedRecord = nil
    }

    // MARK: Inputs

    func handle(measurement: HeartRateMeasurement, at timestamp: Timestamp) {
        guard let session else { return }
        // A BLE packet may be the only thing waking the app in the background:
        // advance the state machine first so the sample lands in the right phase.
        process(session.tick())
        if measurement.isUsable, sensor.signal(at: timestamp).liveBPM != nil {
            session.record(bpm: measurement.bpm, at: timestamp)
        }
        refresh()
    }

    func scenePhaseChanged(isActive active: Bool) {
        appIsActive = active
        guard let session else { return }
        if active {
            notifier.cancelAll()
            process(session.tick())
            refresh()
        } else {
            session.persist(force: true)
            scheduleBackupAlerts()
        }
    }

    // MARK: Event routing

    private func process(_ events: [WorkoutEvent]) {
        guard let session else { return }
        let s = settings()
        for event in events {
            switch event {
            case .phaseChanged(_, let to, _):
                phaseChangeCount += 1
                let kind = session.plan.phases[to].kind
                let active = appIsActive
                Task { [weak self] in
                    guard let self else { return }
                    if let line = await self.music.phaseStarted(kind, appIsActive: active), s.coaching.voiceEnabled {
                        self.audio.speak(line, delay: 0.3)
                    }
                }
            case .cue(let cue):
                let progress = session.progress()
                let action = CoachingScript.action(for: cue, plan: session.plan, maxHR: session.maxHeartRate,
                                                   currentBPM: sensor.signal().liveBPM,
                                                   remaining: progress.phaseRemaining, settings: s.coaching)
                audio.perform(CoachingAction(speech: action.speech, sound: action.sound, haptic: nil))
                if let haptic = action.haptic, appIsActive { Haptics.play(haptic) }
            case .paused:
                notifier.cancelAll()
                music.pauseMusic()
            case .resumed:
                music.resumeMusic()
            case .completed:
                let action = CoachingScript.completionAction(settings: s.coaching)
                audio.perform(CoachingAction(speech: action.speech, sound: action.sound, haptic: nil))
                if let haptic = action.haptic, appIsActive { Haptics.play(haptic) }
                finish(session: session, save: true)
                return
            case .preparationStarted, .workoutStarted, .phaseRestarted, .cancelled:
                break
            }
        }
    }

    private func finish(session finished: WorkoutSession, save: Bool) {
        stopTimer()
        notifier.cancelAll()
        music.endSession()
        if save, let record = finished.makeRecord() {
            do {
                try history.save(record)
                finishedRecord = record
                onHistoryChanged?()
            } catch {
                saveError = "Could not save workout: \(error.localizedDescription)"
                finishedRecord = record
            }
        }
        finished.discardPersistedState()
        session = nil
        progress = nil
        restoredFromTermination = false
        updateIdleTimer()
    }

    // MARK: Timer & display

    private func startTimer() {
        stopTimer()
        // Display refresh only. Correctness never depends on this firing.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let session else { return }
        process(session.tick())
        refresh()
    }

    private func refresh() {
        guard let session else { return }
        let p = session.progress()
        progress = p
        signal = sensor.signal()
        target = p.phase.flatMap { HeartRateZones.target(for: $0.kind, maxHR: session.maxHeartRate) }
        zone = p.phase == nil ? .unavailable : HeartRateZones.status(bpm: signal.liveBPM, target: target)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = session != nil && settings().keepScreenAwake
    }

    private func scheduleBackupAlerts() {
        guard let session, settings().coaching.lockScreenAlerts else { return }
        let upcoming = session.engine.upcomingPhaseStarts(at: session.now())
        notifier.schedule(upcoming: upcoming, plan: session.plan, maxHR: session.maxHeartRate)
    }
}
