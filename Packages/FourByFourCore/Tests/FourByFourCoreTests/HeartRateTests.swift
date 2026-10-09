import XCTest
@testable import FourByFourCore

final class HeartRateParsingTests: XCTestCase {
    func testUInt8ValueWithoutContactFeature() throws {
        let m = try HeartRateMeasurement.parse([0x00, 72])
        XCTAssertEqual(m.bpm, 72)
        XCTAssertEqual(m.contact, .notSupported)
        XCTAssertNil(m.energyExpended)
        XCTAssertTrue(m.rrIntervals.isEmpty)
        XCTAssertTrue(m.isUsable)
    }

    func testUInt16Value() throws {
        let m = try HeartRateMeasurement.parse([0x01, 0x2C, 0x01]) // 300 little-endian
        XCTAssertEqual(m.bpm, 300)
    }

    func testContactDetectedAndNotDetected() throws {
        XCTAssertEqual(try HeartRateMeasurement.parse([0x06, 80]).contact, .detected)
        let lost = try HeartRateMeasurement.parse([0x04, 80])
        XCTAssertEqual(lost.contact, .notDetected)
        XCTAssertFalse(lost.isUsable)
    }

    func testTypicalPolarH10PacketWithRRIntervals() throws {
        // flags 0x16: UInt8 HR, contact supported+detected, RR present.
        // HR 145, RR = 420/1024 s and 415/1024 s.
        let m = try HeartRateMeasurement.parse([0x16, 145, 0xA4, 0x01, 0x9F, 0x01])
        XCTAssertEqual(m.bpm, 145)
        XCTAssertEqual(m.contact, .detected)
        XCTAssertEqual(m.rrIntervals.count, 2)
        XCTAssertEqual(m.rrIntervals[0], 420.0 / 1024.0, accuracy: 1e-9)
        XCTAssertEqual(m.rrIntervals[1], 415.0 / 1024.0, accuracy: 1e-9)
    }

    func testEnergyExpendedAndUInt16WithRR() throws {
        // flags: UInt16 HR | energy | RR = 0x01 | 0x08 | 0x10 = 0x19
        let m = try HeartRateMeasurement.parse([0x19, 0x96, 0x00, 0x10, 0x27, 0x00, 0x04])
        XCTAssertEqual(m.bpm, 150)
        XCTAssertEqual(m.energyExpended, 10_000)
        XCTAssertEqual(m.rrIntervals, [1.0])
    }

    func testMalformedPackets() {
        XCTAssertThrowsError(try HeartRateMeasurement.parse([UInt8]())) { XCTAssertEqual($0 as? HeartRateMeasurement.ParseError, .empty) }
        XCTAssertThrowsError(try HeartRateMeasurement.parse([0x00])) { XCTAssertEqual($0 as? HeartRateMeasurement.ParseError, .truncated) }
        XCTAssertThrowsError(try HeartRateMeasurement.parse([0x01, 0x50])) { XCTAssertEqual($0 as? HeartRateMeasurement.ParseError, .truncated) }
        XCTAssertThrowsError(try HeartRateMeasurement.parse([0x08, 0x50, 0x01])) { XCTAssertEqual($0 as? HeartRateMeasurement.ParseError, .truncated) }
    }

    func testTrailingOddRRByteIsIgnored() throws {
        let m = try HeartRateMeasurement.parse([0x10, 60, 0x00, 0x04, 0x01])
        XCTAssertEqual(m.rrIntervals, [1.0])
    }

    func testZeroBPMIsNotUsable() throws {
        XCTAssertFalse(try HeartRateMeasurement.parse([0x00, 0]).isUsable)
    }

    func testBatteryLevel() {
        XCTAssertEqual(BatteryLevel.parse([87]), 87)
        XCTAssertNil(BatteryLevel.parse([]))
        XCTAssertNil(BatteryLevel.parse([200]))
    }
}

final class HeartRateZoneTests: XCTestCase {
    func testAgeEstimate() {
        XCTAssertEqual(HeartRateProfile.estimatedMax(age: 40), 180)
        let profile = HeartRateProfile.estimated(age: 35)
        XCTAssertEqual(profile.maxHeartRate, 185)
        XCTAssertEqual(profile.source, .ageEstimate)
    }

    func testTargetsForHRmax185() {
        // 0.85 × 185 = 157.25 → 157; 0.95 × 185 = 175.75 → 176
        XCTAssertEqual(HeartRateZones.target(for: .interval, maxHR: 185), BPMRange(lower: 157, upper: 176))
        // 0.60 × 185 = 111 ; 0.70 × 185 = 129.5 → 130 (halves round up)
        XCTAssertEqual(HeartRateZones.target(for: .recovery, maxHR: 185), BPMRange(lower: 111, upper: 130))
        XCTAssertNil(HeartRateZones.target(for: .warmUp, maxHR: 185))
        XCTAssertNil(HeartRateZones.target(for: .coolDown, maxHR: 185))
    }

    func testTargetsForHRmax200() {
        XCTAssertEqual(HeartRateZones.target(for: .interval, maxHR: 200), BPMRange(lower: 170, upper: 190))
        XCTAssertEqual(HeartRateZones.target(for: .recovery, maxHR: 200), BPMRange(lower: 120, upper: 140))
    }

    func testZoneStatusUsesInclusiveRoundedBounds() {
        let target = BPMRange(lower: 157, upper: 176)
        XCTAssertEqual(HeartRateZones.status(bpm: 156, target: target), .below)
        XCTAssertEqual(HeartRateZones.status(bpm: 157, target: target), .within)
        XCTAssertEqual(HeartRateZones.status(bpm: 176, target: target), .within)
        XCTAssertEqual(HeartRateZones.status(bpm: 177, target: target), .above)
        XCTAssertEqual(HeartRateZones.status(bpm: nil, target: target), .unavailable)
        XCTAssertEqual(HeartRateZones.status(bpm: 120, target: nil), .noTarget)
    }

    func testPercentOfMax() {
        XCTAssertEqual(HeartRateZones.percentOfMax(bpm: 171, maxHR: 190), 90)
    }
}

final class HeartRateSignalTests: XCTestCase {
    let t0 = Timestamp(wall: Date(timeIntervalSince1970: 0), monotonic: 100, bootID: "b")

    func testNoReadingIsUnavailable() {
        XCTAssertEqual(HeartRateSignal.evaluate(lastBPM: nil, lastReceived: nil, contact: nil, now: t0), .unavailable)
    }

    func testFreshReadingIsLive() {
        let state = HeartRateSignal.evaluate(lastBPM: 140, lastReceived: t0, contact: .detected, now: t0.adding(1))
        XCTAssertEqual(state, .live(bpm: 140))
        XCTAssertEqual(state.liveBPM, 140)
    }

    func testOldReadingIsStaleAndNotLive() {
        let state = HeartRateSignal.evaluate(lastBPM: 140, lastReceived: t0, contact: .detected, now: t0.adding(5.5))
        XCTAssertEqual(state, .stale(lastBPM: 140, age: 5.5))
        XCTAssertNil(state.liveBPM)
    }

    func testLostContactIsNotLive() {
        let state = HeartRateSignal.evaluate(lastBPM: 140, lastReceived: t0, contact: .notDetected, now: t0.adding(1))
        XCTAssertEqual(state, .noContact)
        XCTAssertNil(state.liveBPM)
    }
}
