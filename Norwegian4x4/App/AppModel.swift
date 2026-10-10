import FourByFourCore
import Foundation
import Observation

/// Composition root: owns settings, stores and long-lived services.
@Observable
@MainActor
final class AppModel {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
            music.update(preferences: settings.music)
        }
    }
    private(set) var history: [WorkoutOverview] = []

    let sensor: HeartRateSensorManager
    let music: MusicCenter
    let workout: WorkoutController
    let health: HealthExporter

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored let historyStore: HistoryStore
    @ObservationIgnored private let activeStore: ActiveSessionStore

    init() {
        let files = JSONFileStore.applicationSupport()
        let settingsStore = SettingsStore(store: files)
        let historyStore = HistoryStore(store: files)
        let activeStore = ActiveSessionStore(store: files)
        let loaded = settingsStore.load()

        let sensor = HeartRateSensorManager(preferred: loaded.preferredSensor)
        let music = MusicCenter(preferences: loaded.music)
        let audio = CoachingAudio()
        let health = HealthExporter()

        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.activeStore = activeStore
        self.settings = loaded
        self.sensor = sensor
        self.music = music
        self.health = health
        // The controller reads settings lazily through this closure.
        var settingsProvider: () -> AppSettings = { loaded }
        self.workout = WorkoutController(settings: { settingsProvider() }, sensor: sensor, music: music, audio: audio,
                                         health: health, history: historyStore, activeStore: activeStore)
        settingsProvider = { [unowned self] in self.settings }

        history = historyStore.overviews()
        workout.onHistoryChanged = { [weak self] in self?.reloadHistory() }
        sensor.onMeasurement = { [weak self] measurement, timestamp in
            MainActor.assumeIsolated { self?.workout.handle(measurement: measurement, at: timestamp) }
        }
        sensor.onPreferredSensorChanged = { [weak self] preference in
            MainActor.assumeIsolated { self?.settings.preferredSensor = preference }
        }

        // Only touch Bluetooth at launch if a sensor was paired before, so the
        // permission prompt appears in context (on the sensor setup screen).
        if loaded.preferredSensor != nil { sensor.activate() }
        workout.restoreIfNeeded()
    }

    func reloadHistory() {
        history = historyStore.overviews()
    }

    var lastWorkout: WorkoutOverview? { history.first }

    func deleteWorkout(id: UUID) {
        historyStore.delete(id: id)
        reloadHistory()
    }

    func deleteAllHistory() {
        historyStore.deleteAll()
        reloadHistory()
    }

    func resetSettings() {
        let sensorPreference = settings.preferredSensor
        var fresh = AppSettings()
        fresh.preferredSensor = sensorPreference
        fresh.hasCompletedOnboarding = true
        settings = fresh
    }

    func forgetSensor() {
        sensor.disconnect(forget: true)
    }
}
