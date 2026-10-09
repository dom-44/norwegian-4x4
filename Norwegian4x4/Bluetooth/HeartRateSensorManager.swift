import CoreBluetooth
import FourByFourCore
import Foundation
import Observation
import os

struct DiscoveredSensor: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date

    var isPolarH10: Bool { name.localizedCaseInsensitiveContains("Polar H10") }

    /// Rough signal description for the setup screen.
    var signalDescription: String {
        switch rssi {
        case -60...0: return "Excellent"
        case -75 ..< -60: return "Good"
        case -90 ..< -75: return "Weak"
        default: return "Very weak"
        }
    }
}

enum SensorConnectionState: Equatable {
    case bluetoothOff
    case unauthorized
    case unsupported
    /// Bluetooth is available but no sensor is connected or being connected.
    case idle
    case scanning
    case connecting(name: String)
    case connected(name: String)
    /// Link lost; a pending connection is waiting for the sensor to come back.
    case reconnecting(name: String)
    case failed(message: String)

    var label: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied"
        case .unsupported: return "Bluetooth LE not supported"
        case .idle: return "Not connected"
        case .scanning: return "Scanning…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .connected(let name): return name
        case .reconnecting(let name): return "Reconnecting to \(name)…"
        case .failed(let message): return message
        }
    }

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

/// Real Core Bluetooth heart-rate client (Bluetooth SIG Heart Rate Service
/// 0x180D / Heart Rate Measurement 0x2A37, Battery 0x180F / 0x2A19).
/// Works with the Polar H10 and any other standard BLE heart-rate strap.
@Observable
final class HeartRateSensorManager: NSObject {
    private(set) var state: SensorConnectionState = .idle
    private(set) var discovered: [DiscoveredSensor] = []
    private(set) var batteryLevel: Int? = nil
    private(set) var lastBPM: Int? = nil
    private(set) var lastReceived: Timestamp? = nil
    private(set) var contact: SensorContact? = nil
    private(set) var lastRRIntervals: [TimeInterval] = []
    private(set) var connectedSensor: SensorPreference? = nil
    private(set) var reconnectAttempts = 0

    /// Called on the main queue for every valid measurement packet.
    @ObservationIgnored var onMeasurement: ((HeartRateMeasurement, Timestamp) -> Void)?
    /// Called when the user picks a sensor so it can be remembered.
    @ObservationIgnored var onPreferredSensorChanged: ((SensorPreference?) -> Void)?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var preferred: SensorPreference?
    @ObservationIgnored private var userInitiatedDisconnect = false
    /// A scan was requested before Bluetooth was powered on.
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private let time: TimeSource
    @ObservationIgnored private let log = Logger(subsystem: "Norwegian4x4", category: "BLE")

    static let heartRateService = CBUUID(string: GATT.heartRateService)
    static let heartRateMeasurement = CBUUID(string: GATT.heartRateMeasurement)
    static let batteryService = CBUUID(string: GATT.batteryService)
    static let batteryLevelCharacteristic = CBUUID(string: GATT.batteryLevel)
    static let restoreIdentifier = "Norwegian4x4.central"

    init(preferred: SensorPreference?, time: TimeSource = SystemTimeSource.shared) {
        self.preferred = preferred
        self.time = time
        super.init()
    }

    /// Creates the central manager. Creating it triggers the Bluetooth
    /// permission prompt the first time, so this is deferred until the user
    /// opens sensor setup or a sensor was already paired before.
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier
        ])
    }

    var hasPreferredSensor: Bool { preferred != nil }
    var preferredName: String? { preferred?.name }

    func signal(at now: Timestamp? = nil) -> HeartRateSignal.State {
        guard state.isConnected else {
            // Never show a reading as current without an active link.
            if let lastBPM, let lastReceived { return .stale(lastBPM: lastBPM, age: lastReceived.seconds(until: now ?? time.now())) }
            return .unavailable
        }
        return HeartRateSignal.evaluate(lastBPM: lastBPM, lastReceived: lastReceived, contact: contact, now: now ?? time.now())
    }

    // MARK: Scanning

    func startScan() {
        activate()
        wantsScan = true
        guard let central, central.state == .poweredOn else { return }
        discovered.removeAll()
        // Sensors already connected to iOS (e.g. by another app) do not advertise.
        for p in central.retrieveConnectedPeripherals(withServices: [Self.heartRateService]) {
            upsert(id: p.identifier, name: p.name ?? "Heart rate sensor", rssi: -50)
        }
        central.scanForPeripherals(withServices: [Self.heartRateService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        if !state.isConnected, peripheral == nil { state = .scanning }
        log.info("Scan started")
    }

    func stopScan() {
        wantsScan = false
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    private func upsert(id: UUID, name: String, rssi: Int) {
        if let i = discovered.firstIndex(where: { $0.id == id }) {
            discovered[i].rssi = rssi
            discovered[i].name = name
            discovered[i].lastSeen = Date()
        } else {
            discovered.append(DiscoveredSensor(id: id, name: name, rssi: rssi, lastSeen: Date()))
            discovered.sort { ($0.isPolarH10 ? 0 : 1, -$0.rssi) < ($1.isPolarH10 ? 0 : 1, -$1.rssi) }
        }
    }

    // MARK: Connection

    func connect(to sensor: DiscoveredSensor) {
        guard let central, let target = central.retrievePeripherals(withIdentifiers: [sensor.id]).first else { return }
        stopScan()
        let pref = SensorPreference(identifier: sensor.id, name: sensor.name)
        preferred = pref
        onPreferredSensorChanged?(pref)
        connect(peripheral: target, name: sensor.name)
    }

    private func connect(peripheral target: CBPeripheral, name: String) {
        if let existing = peripheral, existing.identifier != target.identifier {
            userInitiatedDisconnect = true
            central?.cancelPeripheralConnection(existing)
        }
        userInitiatedDisconnect = false
        peripheral = target
        target.delegate = self
        state = .connecting(name: name)
        // No timeout: a pending connect completes whenever the sensor comes into
        // range, which is also the most power-efficient way to reconnect.
        central?.connect(target, options: nil)
    }

    /// Re-establishes the link to the remembered sensor (manual reconnect).
    func reconnect() {
        activate()
        guard let central, central.state == .poweredOn, let preferred else { return }
        retryTask?.cancel()
        reconnectAttempts = 0
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetReading()
        if let target = central.retrievePeripherals(withIdentifiers: [preferred.identifier]).first {
            connect(peripheral: target, name: preferred.name)
        } else {
            state = .failed(message: "Sensor not found. Scan again.")
        }
    }

    func disconnect(forget: Bool) {
        retryTask?.cancel()
        userInitiatedDisconnect = true
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        connectedSensor = nil
        batteryLevel = nil
        resetReading()
        state = .idle
        if forget {
            preferred = nil
            onPreferredSensorChanged?(nil)
        }
    }

    private func resetReading() {
        lastBPM = nil
        lastReceived = nil
        contact = nil
        lastRRIntervals = []
    }

    private func connectPreferredIfPossible() {
        guard let central, let preferred, peripheral == nil || peripheral?.state == .disconnected else { return }
        if let target = central.retrievePeripherals(withIdentifiers: [preferred.identifier]).first {
            connect(peripheral: target, name: preferred.name)
        }
    }

    private func scheduleRetry(name: String) {
        retryTask?.cancel()
        reconnectAttempts += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempts, 5))))
        state = .reconnecting(name: name)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, let central = self.central, central.state == .poweredOn, let target = self.peripheral else { return }
            central.connect(target, options: nil)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateSensorManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if case .connected = state, let peripheral, peripheral.state == .connected {
                peripheral.discoverServices([Self.heartRateService, Self.batteryService])
            } else {
                state = .idle
                connectPreferredIfPossible()
                if wantsScan, !state.isConnected, peripheral == nil { startScan() }
            }
        case .poweredOff:
            state = .bluetoothOff
            resetReading()
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .unsupported
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // App relaunched by iOS for a Bluetooth event: re-adopt the peripheral.
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
            let name = restored.name ?? preferred?.name ?? "Heart rate sensor"
            if restored.state == .connected {
                state = .connected(name: name)
                connectedSensor = SensorPreference(identifier: restored.identifier, name: name)
            } else {
                state = .connecting(name: name)
            }
            log.info("Restored BLE state")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Heart rate sensor"
        let rssi = RSSI.intValue
        guard rssi != 127 else { return } // 127 = RSSI not available
        upsert(id: peripheral.identifier, name: name, rssi: rssi)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        retryTask?.cancel()
        reconnectAttempts = 0
        let name = peripheral.name ?? preferred?.name ?? "Heart rate sensor"
        state = .connected(name: name)
        connectedSensor = SensorPreference(identifier: peripheral.identifier, name: name)
        peripheral.discoverServices([Self.heartRateService, Self.batteryService])
        log.info("Connected")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("Connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        scheduleRetry(name: peripheral.name ?? preferred?.name ?? "sensor")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Ignore late callbacks for a sensor we already switched away from.
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        resetReading()
        batteryLevel = nil
        connectedSensor = nil
        if userInitiatedDisconnect || peripheral.identifier != preferred?.identifier {
            self.peripheral = nil
            state = .idle
            return
        }
        // Out of range / strap removed: queue a pending connection which iOS
        // completes automatically (also in the background) when it reappears.
        log.info("Disconnected, waiting to reconnect")
        state = .reconnecting(name: peripheral.name ?? preferred?.name ?? "sensor")
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateSensorManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            state = .failed(message: "Could not read sensor services.")
            return
        }
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case Self.heartRateService:
                peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
            case Self.batteryService:
                peripheral.discoverCharacteristics([Self.batteryLevelCharacteristic], for: service)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.heartRateMeasurement:
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.batteryLevelCharacteristic:
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.heartRateMeasurement:
            guard let measurement = try? HeartRateMeasurement.parse(data) else { return }
            let now = time.now()
            contact = measurement.contact
            lastRRIntervals = measurement.rrIntervals
            if measurement.isUsable {
                lastBPM = measurement.bpm
                lastReceived = now
            }
            onMeasurement?(measurement, now)
        case Self.batteryLevelCharacteristic:
            batteryLevel = BatteryLevel.parse([UInt8](data))
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error, characteristic.uuid == Self.heartRateMeasurement {
            log.error("Notify failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(message: "Could not subscribe to heart rate.")
        }
    }
}
