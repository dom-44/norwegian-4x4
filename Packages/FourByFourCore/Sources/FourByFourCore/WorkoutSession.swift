import Foundation

/// A workout in progress: the state machine plus recorded heart rate, with
/// crash-safe persistence. Contains no UI, audio or Bluetooth code.
public final class WorkoutSession {
    public private(set) var engine: WorkoutEngine
    public private(set) var samples: [HeartRateSample]
    public let maxHeartRate: Int
    public var sensorName: String?
    /// True when this session was reconstructed from disk after the app was terminated.
    public let wasRestored: Bool

    private let time: TimeSource
    private let store: ActiveSessionStore?
    private var persistedSampleCount = 0
    /// Samples are flushed at least this often (count) in addition to every state change.
    public static let sampleFlushInterval = 15

    public init(plan: WorkoutPlan, maxHeartRate: Int, sensorName: String?, time: TimeSource, store: ActiveSessionStore?, preparationDuration: TimeInterval = 5) {
        self.engine = WorkoutEngine(plan: plan, createdAt: time.now().wall, preparationDuration: preparationDuration)
        self.samples = []
        self.maxHeartRate = maxHeartRate
        self.sensorName = sensorName
        self.time = time
        self.store = store
        self.wasRestored = false
    }

    /// Restores an unfinished session saved by a previous process, if any.
    public init?(restoringFrom store: ActiveSessionStore, time: TimeSource) {
        guard let state = store.load(), state.snapshot.status.isActive else { return nil }
        self.engine = WorkoutEngine(snapshot: state.snapshot)
        self.samples = state.samples
        self.maxHeartRate = state.maxHeartRate
        self.sensorName = state.sensorName
        self.time = time
        self.store = store
        self.wasRestored = true
        self.persistedSampleCount = state.samples.count
    }

    public var snapshot: WorkoutSnapshot { engine.snapshot }
    public var status: WorkoutStatus { engine.status }
    public var plan: WorkoutPlan { engine.plan }

    public func now() -> Timestamp { time.now() }

    // MARK: Commands (each persists immediately)

    public func start() -> [WorkoutEvent] { mutate { $0.start(at: $1) } }
    public func pause() -> [WorkoutEvent] { mutate { $0.pause(at: $1) } }
    public func resume() -> [WorkoutEvent] { mutate { $0.resume(at: $1) } }
    public func skipPhase() -> [WorkoutEvent] { mutate { $0.skipPhase(at: $1) } }
    public func restartPhase() -> [WorkoutEvent] { mutate { $0.restartPhase(at: $1) } }
    public func cancel() -> [WorkoutEvent] { mutate { $0.cancel(at: $1) } }

    public func restartWorkout() -> [WorkoutEvent] {
        samples = []
        persistedSampleCount = 0
        return mutate { $0.restartWorkout(at: $1) }
    }

    /// Advances to the current time. Call frequently (UI timer, BLE callbacks,
    /// foreground transitions); it is cheap and idempotent.
    public func tick() -> [WorkoutEvent] { mutate { $0.update(at: $1) } }

    private func mutate(_ body: (inout WorkoutEngine, Timestamp) -> [WorkoutEvent]) -> [WorkoutEvent] {
        let before = engine.snapshot
        let events = body(&engine, time.now())
        if engine.snapshot != before { persist(force: true) }
        return events
    }

    public func progress() -> WorkoutProgress { engine.progress(at: time.now()) }

    // MARK: Heart rate

    /// Records a live reading. Ignored unless the workout clock is running.
    @discardableResult
    public func record(bpm: Int, at timestamp: Timestamp? = nil) -> HeartRateSample? {
        let now = timestamp ?? time.now()
        guard engine.status == .running, bpm > 0 else { return nil }
        let position = engine.timelinePosition(at: now)
        guard let index = plan.phaseIndex(at: position) else { return nil }
        let sample = HeartRateSample(t: engine.activeElapsed(at: now), phaseIndex: index,
                                     phaseOffset: position - plan.startOffset(ofPhase: index), bpm: bpm)
        samples.append(sample)
        if samples.count - persistedSampleCount >= Self.sampleFlushInterval { persist(force: true) }
        return sample
    }

    // MARK: Persistence

    public func persist(force: Bool = false) {
        guard let store else { return }
        if !force && samples.count == persistedSampleCount { return }
        if engine.status.isActive {
            let state = ActiveSessionState(snapshot: engine.snapshot, samples: samples, maxHeartRate: maxHeartRate, sensorName: sensorName)
            if (try? store.save(state)) != nil { persistedSampleCount = samples.count }
        } else {
            store.clear()
        }
    }

    public func discardPersistedState() { store?.clear() }

    // MARK: Results

    public func summary() -> WorkoutSummary {
        WorkoutStatistics.summarize(samples: samples, plan: plan, maxHR: maxHeartRate,
                                    activeDuration: engine.activeElapsed(at: time.now()),
                                    skippedPhases: engine.snapshot.skippedPhases)
    }

    /// History record for a finished session. Nil if the workout never started.
    public func makeRecord() -> WorkoutRecord? {
        let snap = engine.snapshot
        guard snap.status == .completed || snap.status == .cancelled, let startedAt = snap.startedAt else { return nil }
        return WorkoutRecord(id: snap.sessionID, startedAt: startedAt, endedAt: snap.endedAt ?? time.now().wall,
                             completed: snap.status == .completed, plan: plan, maxHeartRate: maxHeartRate,
                             sensorName: sensorName, samples: samples, summary: summary())
    }
}
