import XCTest
@testable import FourByFourCore

final class HealthExportTests: XCTestCase {
    private func record(bpm: Int = 150, seconds: Int = 60) throws -> WorkoutRecord {
        let clock = ManualTimeSource()
        let session = WorkoutSession(plan: .standard, maxHeartRate: 190, sensorName: nil, time: clock, store: nil, preparationDuration: 0)
        _ = session.start()
        for _ in 0..<seconds { clock.advance(1); session.record(bpm: bpm) }
        _ = session.cancel()
        return try XCTUnwrap(session.makeRecord())
    }

    func testHeartRateIsThinnedToEveryFiveSeconds() throws {
        let r = try record(seconds: 60)
        let points = HealthExport.heartRatePoints(for: r)
        XCTAssertEqual(points.count, 12, "60 one-second samples → one point per 5 s")
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertEqual(b.date.timeIntervalSince(a.date), 5, accuracy: 0.001)
        }
        XCTAssertTrue(points.allSatisfy { $0.date >= r.startedAt && $0.date <= r.endedAt })
    }

    func testEnergyNeedsBodyData() throws {
        let r = try record()
        XCTAssertNil(HealthExport.activeEnergy(samples: r.samples, weightKg: nil, age: 35, sex: .male))
        XCTAssertNil(HealthExport.activeEnergy(samples: r.samples, weightKg: 75, age: nil, sex: .male))
        XCTAssertNil(HealthExport.activeEnergy(samples: r.samples, weightKg: 75, age: 35, sex: nil))
    }

    func testKeytelEstimateIsPlausible() throws {
        // 35-year-old, 75 kg man at 150 bpm: Keytel ≈ 14.7 kcal/min.
        XCTAssertEqual(HealthExport.kcalPerMinute(heartRate: 150, weightKg: 75, age: 35, sex: .male), 14.7, accuracy: 0.1)
        let r = try record(bpm: 150, seconds: 600)
        let kcal = try XCTUnwrap(HealthExport.activeEnergy(samples: r.samples, weightKg: 75, age: 35, sex: .male))
        XCTAssertEqual(kcal, 14.7 * 599 / 60, accuracy: 3) // 599 one-second gaps
        let female = try XCTUnwrap(HealthExport.activeEnergy(samples: r.samples, weightKg: 60, age: 35, sex: .female))
        XCTAssertLessThan(female, kcal)
    }

    func testLongGapsAreNotCounted() {
        let samples = [
            HeartRateSample(t: 0, phaseIndex: 0, phaseOffset: 0, bpm: 150),
            HeartRateSample(t: 10, phaseIndex: 0, phaseOffset: 10, bpm: 150),
            HeartRateSample(t: 310, phaseIndex: 0, phaseOffset: 310, bpm: 150), // sensor off for 5 min
        ]
        let kcal = HealthExport.activeEnergy(samples: samples, weightKg: 75, age: 35, sex: .male) ?? 0
        XCTAssertEqual(kcal, HealthExport.kcalPerMinute(heartRate: 150, weightKg: 75, age: 35, sex: .male) * 10 / 60, accuracy: 0.01)
    }

    func testOldSettingsWithoutHealthStillDecode() throws {
        var settings = AppSettings()
        settings.health = HealthSettings(enabled: true, activity: .running)
        let data = try JSONEncoder().encode(settings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "health")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.health)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).health?.activity, .running)
    }
}
