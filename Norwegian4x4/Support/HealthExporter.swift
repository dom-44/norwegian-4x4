import FourByFourCore
import Foundation
import HealthKit
import os

/// Saves finished workouts to Apple Health: a workout of the chosen type with
/// the heart-rate curve from the strap and, if weight / age / sex are known in
/// Health, an estimated active energy. Only called after the user enabled it.
@MainActor
final class HealthExporter {
    private let store = HKHealthStore()
    private let log = Logger(subsystem: "Norwegian4x4", category: "Health")

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
    }

    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.bodyMass), HKCharacteristicType(.dateOfBirth), HKCharacteristicType(.biologicalSex)]
    }

    /// Shows the Health permission sheet (only the first time). Fails if
    /// HealthKit is unavailable or the request is rejected, e.g. because the
    /// HealthKit entitlement was lost when the app was signed.
    func requestAuthorization() async -> Result<Void, Error> {
        guard isAvailable else { return .failure(HealthExportError.unavailable) }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            return .success(())
        } catch {
            log.error("Health authorization failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    /// Whether the user allowed writing workouts (reading permissions are never revealed by iOS).
    var canSaveWorkouts: Bool {
        isAvailable && store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    func save(_ record: WorkoutRecord, activity: HealthActivity, fallbackAge: Int?) async throws {
        guard isAvailable else { throw HealthExportError.unavailable }
        guard canSaveWorkouts else { throw HealthExportError.notAuthorized }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity.hkType
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: record.startedAt)

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = HealthExport.heartRatePoints(for: record).map { point in
            HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(point.bpm)),
                             start: point.date, end: point.date)
        }
        let weight = await latestWeightKg()
        let kcal = HealthExport.activeEnergy(samples: record.samples, weightKg: weight,
                                             age: age() ?? fallbackAge, sex: sex())
        if let kcal {
            samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal),
                                            start: record.startedAt, end: record.endedAt))
        }
        if !samples.isEmpty { try await builder.addSamples(samples) }
        try await builder.addMetadata([HKMetadataKeyIndoorWorkout: true,
                                       HKMetadataKeyExternalUUID: record.id.uuidString])
        try await builder.endCollection(at: record.endedAt)
        _ = try await builder.finishWorkout()
        log.info("Saved workout to Health (\(samples.count) samples, energy: \(kcal != nil, privacy: .public))")
    }

    private func latestWeightKg() async -> Double? {
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
                                                 sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        let result = try? await descriptor.result(for: store)
        return result?.first?.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }

    private func age() -> Int? {
        guard let birth = try? store.dateOfBirthComponents(), let date = Calendar.current.date(from: birth) else { return nil }
        return Calendar.current.dateComponents([.year], from: date, to: Date()).year
    }

    private func sex() -> HealthSex? {
        switch (try? store.biologicalSex())?.biologicalSex {
        case .female: return .female
        case .male: return .male
        default: return nil
        }
    }
}

enum HealthExportError: LocalizedError {
    case unavailable
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Health is not available on this device."
        case .notAuthorized: return "Allow Norwegian 4x4 to save workouts in Settings › Health › Data Access & Devices."
        }
    }
}

extension HealthActivity {
    var hkType: HKWorkoutActivityType {
        switch self {
        case .intervalTraining: return .highIntensityIntervalTraining
        case .running: return .running
        case .cycling: return .cycling
        case .rowing: return .rowing
        case .elliptical: return .elliptical
        case .stairClimbing: return .stairClimbing
        case .walking: return .walking
        case .other: return .other
        }
    }
}
