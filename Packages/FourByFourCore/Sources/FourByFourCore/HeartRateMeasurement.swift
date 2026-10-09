import Foundation

/// Bluetooth SIG GATT identifiers used by the app.
public enum GATT {
    public static let heartRateService = "180D"
    public static let heartRateMeasurement = "2A37"
    public static let bodySensorLocation = "2A38"
    public static let batteryService = "180F"
    public static let batteryLevel = "2A19"
    public static let deviceInformationService = "180A"
    public static let manufacturerName = "2A29"
}

public enum SensorContact: Equatable, Sendable {
    case notSupported
    case notDetected
    case detected
}

/// Decoded Heart Rate Measurement characteristic (0x2A37).
///
/// Layout (Bluetooth SIG Heart Rate Service 1.0):
/// * byte 0: flags
///   - bit 0: value format (0 = UInt8, 1 = UInt16 little-endian)
///   - bit 1: sensor contact detected
///   - bit 2: sensor contact feature supported
///   - bit 3: energy expended present (UInt16, kJ)
///   - bit 4: RR-intervals present (UInt16 each, 1/1024 s)
/// * heart rate value, then optional energy expended, then RR-intervals.
public struct HeartRateMeasurement: Equatable, Sendable {
    public var bpm: Int
    public var contact: SensorContact
    public var energyExpended: Int?
    /// RR-intervals in seconds.
    public var rrIntervals: [TimeInterval]

    public enum ParseError: Error, Equatable {
        case empty
        case truncated
    }

    public init(bpm: Int, contact: SensorContact, energyExpended: Int? = nil, rrIntervals: [TimeInterval] = []) {
        self.bpm = bpm
        self.contact = contact
        self.energyExpended = energyExpended
        self.rrIntervals = rrIntervals
    }

    public static func parse(_ data: Data) throws -> HeartRateMeasurement {
        try parse([UInt8](data))
    }

    public static func parse(_ bytes: [UInt8]) throws -> HeartRateMeasurement {
        guard let flags = bytes.first else { throw ParseError.empty }
        var index = 1

        func readUInt16() throws -> Int {
            guard index + 1 < bytes.count else { throw ParseError.truncated }
            let value = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
            return value
        }

        let bpm: Int
        if flags & 0x01 != 0 {
            bpm = try readUInt16()
        } else {
            guard index < bytes.count else { throw ParseError.truncated }
            bpm = Int(bytes[index])
            index += 1
        }

        let contact: SensorContact
        if flags & 0x04 == 0 {
            contact = .notSupported
        } else {
            contact = flags & 0x02 != 0 ? .detected : .notDetected
        }

        var energy: Int?
        if flags & 0x08 != 0 {
            energy = try readUInt16()
        }

        var rr: [TimeInterval] = []
        if flags & 0x10 != 0 {
            // Any trailing odd byte is ignored rather than failing the whole packet.
            while index + 1 < bytes.count {
                let raw = try readUInt16()
                rr.append(Double(raw) / 1024.0)
            }
        }

        return HeartRateMeasurement(bpm: bpm, contact: contact, energyExpended: energy, rrIntervals: rr)
    }

    /// Whether this packet represents a usable live heart rate.
    /// A value of 0 or a reported loss of skin contact is not a reading.
    public var isUsable: Bool {
        bpm > 0 && bpm < 255 && contact != .notDetected
    }
}

/// Parses the Battery Level characteristic (0x2A19): one byte, 0–100 %.
public enum BatteryLevel {
    public static func parse(_ bytes: [UInt8]) -> Int? {
        guard let value = bytes.first, value <= 100 else { return nil }
        return Int(value)
    }
}
