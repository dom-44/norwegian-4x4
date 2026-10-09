import Foundation

/// Lifecycle of a workout session.
///
/// Phase transitions are modelled as *events* (`WorkoutEvent.phaseChanged`)
/// emitted exactly once per transition, not as a lasting state: the session is
/// always in exactly one phase while `running` or `paused`.
public enum WorkoutStatus: String, Codable, Sendable {
    case idle
    /// Short countdown before the first phase starts.
    case preparing
    case running
    /// Workout time is frozen. Sensor connection management continues.
    case paused
    case completed
    case cancelled

    public var isActive: Bool { self == .preparing || self == .running || self == .paused }
}

public enum CueKind: Equatable, Sendable {
    /// Start of a phase. `late` is true when the app was not running at the
    /// moment the phase began (e.g. it was suspended) and the cue is a catch-up.
    case phaseStart(late: Bool)
    case midpoint
    /// Seconds remaining in the phase.
    case countdown(Int)
}

public struct WorkoutCue: Equatable, Sendable {
    public var phaseIndex: Int
    public var kind: CueKind
}

public enum WorkoutEvent: Equatable, Sendable {
    case preparationStarted
    case workoutStarted
    /// `skipped` lists phases that started and ended while the app was not
    /// able to observe them (e.g. suspended); they are not announced.
    case phaseChanged(from: Int?, to: Int, skipped: [Int])
    case phaseRestarted(Int)
    case cue(WorkoutCue)
    case paused
    case resumed
    case completed
    case cancelled
}

/// Persistable state of a session. All timing is derived from timestamps; the
/// engine never counts ticks, so missed callbacks (background, suspension,
/// termination) cannot make the timer drift.
public struct WorkoutSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var plan: WorkoutPlan
    public var status: WorkoutStatus
    public var createdAt: Date
    public var preparationDuration: TimeInterval
    public var preparingSince: Timestamp?
    /// Wall-clock time the first phase started (for history).
    public var startedAt: Date?
    /// Active (non-paused) seconds accumulated before the current running segment.
    public var activeAccumulated: TimeInterval
    /// Start of the current running segment; nil unless `running`.
    public var runningSince: Timestamp?
    /// Timeline adjustment from skip / restart-phase commands.
    /// timeline position = active elapsed + offset.
    public var timelineOffset: TimeInterval
    public var pausedAt: Timestamp?
    public var endedAt: Date?
    /// Phase for which a transition has already been emitted. Persisted so a
    /// restored session never re-emits the same transition.
    public var currentPhaseIndex: Int?
    /// Cues already delivered (or deliberately dropped because they were stale).
    public var firedCues: Set<String>
    public var skippedPhases: [Int]
    public var pauseCount: Int

    public init(sessionID: UUID = UUID(), plan: WorkoutPlan, createdAt: Date, preparationDuration: TimeInterval) {
        self.sessionID = sessionID
        self.plan = plan
        self.status = .idle
        self.createdAt = createdAt
        self.preparationDuration = preparationDuration
        self.activeAccumulated = 0
        self.timelineOffset = 0
        self.firedCues = []
        self.skippedPhases = []
        self.pauseCount = 0
    }
}

/// Read-only view of the session at an instant, for the UI.
public struct WorkoutProgress: Equatable, Sendable {
    public var status: WorkoutStatus
    public var phaseIndex: Int?
    public var phase: PhaseDefinition?
    public var nextPhase: PhaseDefinition?
    public var phaseElapsed: TimeInterval
    public var phaseRemaining: TimeInterval
    public var phaseFraction: Double
    /// Real workout time excluding pauses (and excluding preparation).
    public var activeElapsed: TimeInterval
    /// Position on the workout timeline (includes skip / restart adjustments).
    public var timelinePosition: TimeInterval
    public var totalDuration: TimeInterval
    public var totalFraction: Double
    public var totalRemaining: TimeInterval
    public var preparationRemaining: TimeInterval
}

public struct WorkoutEngine: Sendable {
    public struct CueTolerances: Sendable {
        /// A phase-start cue later than this is announced as a catch-up (`late`).
        public var phaseStart: TimeInterval = 4
        /// Midpoint / countdown cues later than this are dropped silently.
        public var midpoint: TimeInterval = 5
        public var countdown: TimeInterval = 1.5
        public init() {}
    }

    public static let countdownMarks = [10, 3, 2, 1]
    public static let minimumPhaseForMidpoint: TimeInterval = 60

    public private(set) var snapshot: WorkoutSnapshot
    public var tolerances = CueTolerances()

    public init(snapshot: WorkoutSnapshot) {
        self.snapshot = snapshot
    }

    public init(plan: WorkoutPlan, createdAt: Date, preparationDuration: TimeInterval = 5) {
        self.snapshot = WorkoutSnapshot(plan: plan, createdAt: createdAt, preparationDuration: preparationDuration)
    }

    public var plan: WorkoutPlan { snapshot.plan }
    public var status: WorkoutStatus { snapshot.status }

    // MARK: - Commands

    /// Begins the preparation countdown (or starts immediately when the
    /// preparation duration is zero).
    public mutating func start(at now: Timestamp) -> [WorkoutEvent] {
        guard snapshot.status == .idle, !plan.phases.isEmpty else { return [] }
        snapshot.status = .preparing
        snapshot.preparingSince = now
        return [.preparationStarted] + update(at: now)
    }

    public mutating func pause(at now: Timestamp) -> [WorkoutEvent] {
        var events = update(at: now)
        guard snapshot.status == .running, let since = snapshot.runningSince else { return events }
        snapshot.activeAccumulated += max(0, since.seconds(until: now))
        snapshot.runningSince = nil
        snapshot.pausedAt = now
        snapshot.status = .paused
        snapshot.pauseCount += 1
        events.append(.paused)
        return events
    }

    public mutating func resume(at now: Timestamp) -> [WorkoutEvent] {
        guard snapshot.status == .paused else { return [] }
        snapshot.status = .running
        snapshot.runningSince = now
        snapshot.pausedAt = nil
        return [.resumed] + update(at: now)
    }

    /// Jumps to the start of the next phase (completes the workout from the
    /// last phase). Works while running or paused.
    public mutating func skipPhase(at now: Timestamp) -> [WorkoutEvent] {
        var events = update(at: now)
        guard snapshot.status == .running || snapshot.status == .paused else { return events }
        let position = timelinePosition(at: now)
        guard let index = plan.phaseIndex(at: position) else { return events }
        snapshot.timelineOffset += plan.endOffset(ofPhase: index) - position
        events += update(at: now)
        return events
    }

    /// Restarts the current phase from its beginning; its cues fire again.
    public mutating func restartPhase(at now: Timestamp) -> [WorkoutEvent] {
        var events = update(at: now)
        guard snapshot.status == .running || snapshot.status == .paused else { return events }
        let position = timelinePosition(at: now)
        guard let index = plan.phaseIndex(at: position) else { return events }
        snapshot.timelineOffset -= position - plan.startOffset(ofPhase: index)
        snapshot.firedCues = snapshot.firedCues.filter { !$0.hasPrefix("p\(index).") }
        events.append(.phaseRestarted(index))
        events += update(at: now)
        return events
    }

    /// Discards progress and starts the same plan again from preparation.
    public mutating func restartWorkout(at now: Timestamp) -> [WorkoutEvent] {
        let prep = snapshot.preparationDuration
        snapshot = WorkoutSnapshot(plan: plan, createdAt: now.wall, preparationDuration: prep)
        return start(at: now)
    }

    public mutating func cancel(at now: Timestamp) -> [WorkoutEvent] {
        guard snapshot.status.isActive else { return [] }
        var events = update(at: now)
        guard snapshot.status.isActive else { return events } // completed during update
        if let since = snapshot.runningSince {
            snapshot.activeAccumulated += max(0, since.seconds(until: now))
        }
        snapshot.runningSince = nil
        snapshot.status = .cancelled
        snapshot.endedAt = now.wall
        events.append(.cancelled)
        return events
    }

    // MARK: - Time evaluation

    /// Advances the state machine to `now` and returns the events that became
    /// due. Idempotent: calling it repeatedly with the same time yields no new
    /// events, and a restored snapshot never repeats delivered events.
    public mutating func update(at now: Timestamp) -> [WorkoutEvent] {
        var events: [WorkoutEvent] = []

        if snapshot.status == .preparing, let prepSince = snapshot.preparingSince {
            let waited = prepSince.seconds(until: now)
            guard waited >= snapshot.preparationDuration else { return events }
            let start = prepSince.adding(snapshot.preparationDuration)
            snapshot.status = .running
            snapshot.runningSince = start
            snapshot.startedAt = start.wall
            snapshot.preparingSince = nil
            events.append(.workoutStarted)
        }

        guard snapshot.status == .running || snapshot.status == .paused else { return events }

        let rawPosition = rawTimelinePosition(at: now)
        let newIndex = plan.phaseIndex(at: rawPosition)

        if let newIndex, newIndex != snapshot.currentPhaseIndex {
            let from = snapshot.currentPhaseIndex
            let firstUnseen = (from ?? -1) + 1
            let skipped = firstUnseen < newIndex ? Array(firstUnseen..<newIndex) : []
            snapshot.skippedPhases += skipped
            snapshot.currentPhaseIndex = newIndex
            events.append(.phaseChanged(from: from, to: newIndex, skipped: skipped))
        }

        if newIndex == nil {
            // Timeline reached the end: freeze active time at the exact completion moment.
            let overshoot = rawPosition - plan.totalDuration
            snapshot.activeAccumulated = activeElapsed(at: now) - max(0, overshoot)
            snapshot.runningSince = nil
            snapshot.status = .completed
            snapshot.endedAt = now.wall.addingTimeInterval(-max(0, overshoot))
            events.append(.completed)
            return events
        }

        if snapshot.status == .running, let index = newIndex {
            events += dueCues(phaseIndex: index, position: rawPosition)
        }
        return events
    }

    private mutating func dueCues(phaseIndex index: Int, position: TimeInterval) -> [WorkoutEvent] {
        var events: [WorkoutEvent] = []
        let phase = plan.phases[index]
        let offset = position - plan.startOffset(ofPhase: index)
        let remaining = phase.duration - offset

        let startKey = "p\(index).start"
        if !snapshot.firedCues.contains(startKey) {
            snapshot.firedCues.insert(startKey)
            events.append(.cue(WorkoutCue(phaseIndex: index, kind: .phaseStart(late: offset > tolerances.phaseStart))))
        }

        if phase.duration >= Self.minimumPhaseForMidpoint, phase.kind == .interval || phase.kind == .recovery {
            let midKey = "p\(index).mid"
            let mid = phase.duration / 2
            if offset >= mid, !snapshot.firedCues.contains(midKey) {
                snapshot.firedCues.insert(midKey)
                if offset - mid <= tolerances.midpoint {
                    events.append(.cue(WorkoutCue(phaseIndex: index, kind: .midpoint)))
                }
            }
        }

        // If several countdown marks became due at once, only announce the latest.
        var countdown: Int?
        for mark in Self.countdownMarks where Double(mark) < phase.duration {
            let key = "p\(index).cd\(mark)"
            guard remaining <= Double(mark), !snapshot.firedCues.contains(key) else { continue }
            snapshot.firedCues.insert(key)
            if Double(mark) - remaining <= tolerances.countdown {
                countdown = mark
            }
        }
        if let countdown {
            events.append(.cue(WorkoutCue(phaseIndex: index, kind: .countdown(countdown))))
        }
        return events
    }

    /// Active (non-paused) workout time.
    public func activeElapsed(at now: Timestamp) -> TimeInterval {
        var elapsed = snapshot.activeAccumulated
        if snapshot.status == .running, let since = snapshot.runningSince {
            elapsed += max(0, since.seconds(until: now))
        }
        return elapsed
    }

    private func rawTimelinePosition(at now: Timestamp) -> TimeInterval {
        max(0, activeElapsed(at: now) + snapshot.timelineOffset)
    }

    public func timelinePosition(at now: Timestamp) -> TimeInterval {
        switch snapshot.status {
        case .idle, .preparing: return 0
        case .completed: return plan.totalDuration
        default: return min(rawTimelinePosition(at: now), plan.totalDuration)
        }
    }

    public func progress(at now: Timestamp) -> WorkoutProgress {
        let total = plan.totalDuration
        let position = timelinePosition(at: now)
        var index: Int?
        switch snapshot.status {
        case .preparing, .idle: index = plan.phases.isEmpty ? nil : 0
        case .completed, .cancelled: index = snapshot.currentPhaseIndex
        case .running, .paused: index = plan.phaseIndex(at: position) ?? snapshot.currentPhaseIndex
        }

        var phaseElapsed: TimeInterval = 0
        var phaseRemaining: TimeInterval = 0
        var phase: PhaseDefinition?
        var next: PhaseDefinition?
        if let index {
            let p = plan.phases[index]
            phase = p
            next = index + 1 < plan.phases.count ? plan.phases[index + 1] : nil
            let start = plan.startOffset(ofPhase: index)
            phaseElapsed = min(max(0, position - start), p.duration)
            phaseRemaining = p.duration - phaseElapsed
        }

        var prepRemaining: TimeInterval = 0
        if snapshot.status == .preparing, let since = snapshot.preparingSince {
            prepRemaining = max(0, snapshot.preparationDuration - since.seconds(until: now))
        }

        return WorkoutProgress(
            status: snapshot.status,
            phaseIndex: index,
            phase: phase,
            nextPhase: next,
            phaseElapsed: phaseElapsed,
            phaseRemaining: phaseRemaining,
            phaseFraction: phase.map { $0.duration > 0 ? phaseElapsed / $0.duration : 0 } ?? 0,
            activeElapsed: activeElapsed(at: now),
            timelinePosition: position,
            totalDuration: total,
            totalFraction: total > 0 ? position / total : 0,
            totalRemaining: max(0, total - position),
            preparationRemaining: prepRemaining
        )
    }

    /// Wall-clock dates at which upcoming phases will start if the workout keeps
    /// running uninterrupted. Used to schedule backup lock-screen alerts.
    public func upcomingPhaseStarts(at now: Timestamp) -> [(phaseIndex: Int, date: Date)] {
        guard snapshot.status == .running || snapshot.status == .preparing else { return [] }
        var leadTime: TimeInterval = 0
        var position: TimeInterval = 0
        if snapshot.status == .preparing, let since = snapshot.preparingSince {
            leadTime = max(0, snapshot.preparationDuration - since.seconds(until: now))
        } else {
            position = timelinePosition(at: now)
        }
        var result: [(phaseIndex: Int, date: Date)] = []
        for index in plan.phases.indices {
            let start = plan.startOffset(ofPhase: index)
            if start > position {
                result.append((phaseIndex: index, date: now.wall.addingTimeInterval(leadTime + start - position)))
            }
        }
        result.append((phaseIndex: plan.phases.count, date: now.wall.addingTimeInterval(leadTime + plan.totalDuration - position)))
        return result
    }
}
