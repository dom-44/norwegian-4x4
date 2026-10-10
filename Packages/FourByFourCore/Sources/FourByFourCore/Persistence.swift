import Foundation

public struct SensorPreference: Codable, Equatable, Sendable {
    public var identifier: UUID
    public var name: String
    public init(identifier: UUID, name: String) {
        self.identifier = identifier
        self.name = name
    }
}

/// All user settings. Stored as one JSON file.
public struct AppSettings: Codable, Equatable, Sendable {
    public var workout: WorkoutConfiguration = .standard
    public var heartRate: HeartRateProfile = .default
    public var coaching = CoachingSettings()
    public var music = MusicPreferences()
    public var preferredSensor: SensorPreference?
    public var keepScreenAwake = true
    public var hasCompletedOnboarding = false
    /// Optional so settings saved before this existed still decode.
    public var health: HealthSettings?

    public init() {}
}

/// Session in progress, persisted so it survives termination.
public struct ActiveSessionState: Codable, Equatable, Sendable {
    public var snapshot: WorkoutSnapshot
    public var samples: [HeartRateSample]
    public var maxHeartRate: Int
    public var sensorName: String?

    public init(snapshot: WorkoutSnapshot, samples: [HeartRateSample], maxHeartRate: Int, sensorName: String?) {
        self.snapshot = snapshot
        self.samples = samples
        self.maxHeartRate = maxHeartRate
        self.sensorName = sensorName
    }
}

/// Atomic JSON file storage in Application Support.
///
/// Files use `completeUntilFirstUserAuthentication` protection so the app can
/// still write while the phone is locked during a workout.
public final class JSONFileStore: @unchecked Sendable {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "JSONFileStore")

    public init(directory: URL) {
        self.directory = directory
        // Default date strategy (Double seconds) keeps sub-second precision,
        // which the restored timestamps rely on.
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func applicationSupport(subdirectory: String = "Norwegian4x4") -> JSONFileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return JSONFileStore(directory: base.appendingPathComponent(subdirectory, isDirectory: true))
    }

    public func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    public func save<T: Encodable>(_ value: T, as name: String) throws {
        let data = try encoder.encode(value)
        try queue.sync {
            let fileURL = url(for: name)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: fileURL, options: [.atomic])
            #endif
        }
    }

    public func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let data: Data? = queue.sync { try? Data(contentsOf: url(for: name)) }
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }

    public func remove(_ name: String) {
        queue.sync { _ = try? FileManager.default.removeItem(at: url(for: name)) }
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }
}

public final class SettingsStore {
    private let store: JSONFileStore
    private static let file = "settings.json"
    public init(store: JSONFileStore) { self.store = store }
    public func load() -> AppSettings { store.load(AppSettings.self, from: Self.file) ?? AppSettings() }
    public func save(_ settings: AppSettings) { try? store.save(settings, as: Self.file) }
    public func reset() { store.remove(Self.file) }
}

public final class ActiveSessionStore {
    private let store: JSONFileStore
    private static let file = "active-session.json"
    public init(store: JSONFileStore) { self.store = store }
    public func load() -> ActiveSessionState? { store.load(ActiveSessionState.self, from: Self.file) }
    public func save(_ state: ActiveSessionState) throws { try store.save(state, as: Self.file) }
    public func clear() { store.remove(Self.file) }
}

/// Workout history: one file per workout plus an index of overviews.
public final class HistoryStore {
    private let store: JSONFileStore
    private static let index = "history/index.json"
    public init(store: JSONFileStore) { self.store = store }

    public func overviews() -> [WorkoutOverview] {
        (store.load([WorkoutOverview].self, from: Self.index) ?? []).sorted { $0.startedAt > $1.startedAt }
    }

    public func record(id: UUID) -> WorkoutRecord? {
        store.load(WorkoutRecord.self, from: "history/\(id.uuidString).json")
    }

    public func save(_ record: WorkoutRecord) throws {
        try store.save(record, as: "history/\(record.id.uuidString).json")
        var all = overviews().filter { $0.id != record.id }
        all.append(record.overview)
        try store.save(all, as: Self.index)
    }

    public func delete(id: UUID) {
        store.remove("history/\(id.uuidString).json")
        let remaining = overviews().filter { $0.id != id }
        try? store.save(remaining, as: Self.index)
    }

    public func deleteAll() {
        for overview in overviews() { store.remove("history/\(overview.id.uuidString).json") }
        store.remove(Self.index)
    }
}
