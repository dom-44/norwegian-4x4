import FourByFourCore
import SwiftUI

struct SensorSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showForgetConfirm = false

    private var sensor: HeartRateSensorManager { model.sensor }

    var body: some View {
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 16) {
                        SensorStatusRow(state: sensor.state, battery: sensor.batteryLevel, signal: sensor.signal())
                        if case .live(let bpm) = sensor.signal() {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(bpm)").font(.system(size: 64, weight: .heavy, design: .rounded).monospacedDigit())
                                Text("bpm").font(.title3).foregroundStyle(Theme.secondaryText)
                                Spacer()
                                if let rr = sensor.lastRRIntervals.last {
                                    Text("RR \(Int(rr * 1000)) ms").font(.footnote.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                stateActions
            }

            if showsDeviceList {
                Section {
                    if sensor.discovered.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for heart rate monitors…").foregroundStyle(Theme.secondaryText)
                        }
                    }
                    ForEach(sensor.discovered) { device in
                        Button {
                            sensor.connect(to: device)
                        } label: {
                            HStack {
                                Image(systemName: device.isPolarH10 ? "heart.circle.fill" : "heart.circle")
                                    .foregroundStyle(device.isPolarH10 ? Theme.accent : Theme.secondaryText)
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text(device.name).font(.headline)
                                    Text(device.isPolarH10 ? "Polar H10 · \(device.signalDescription) signal" : "Heart rate monitor · \(device.signalDescription) signal")
                                        .font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                Text("\(device.rssi) dBm").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Nearby sensors")
                }
            }

            Section("Troubleshooting") {
                TipRow(icon: "drop.fill", text: "Moisten the strap electrodes and wear it snugly below the chest muscles. The H10 only transmits while worn.")
                TipRow(icon: "xmark.app", text: "Close Polar Flow or other apps that may hold the connection, or disconnect the H10 from other devices.")
                TipRow(icon: "battery.25", text: "If it never appears, replace the CR2025 battery in the H10 connector.")
                TipRow(icon: "gear", text: "Do not pair the H10 in iOS Settings > Bluetooth; this app connects to it directly.")
                TipRow(icon: "lock.shield", text: "If Bluetooth permission was denied, enable it in Settings > Privacy & Security > Bluetooth.")
            }

            if sensor.hasPreferredSensor {
                Section {
                    Button("Forget \(sensor.preferredName ?? "sensor")", role: .destructive) { showForgetConfirm = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Heart Rate Sensor")
        .onAppear {
            sensor.activate()
            if !sensor.state.isConnected { sensor.startScan() }
        }
        .onDisappear { sensor.stopScan() }
        .confirmationDialog("Forget this sensor?", isPresented: $showForgetConfirm, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.forgetSensor() }
        }
    }

    private var showsDeviceList: Bool {
        switch sensor.state {
        case .connected, .bluetoothOff, .unauthorized, .unsupported: return false
        default: return true
        }
    }

    @ViewBuilder private var stateActions: some View {
        switch sensor.state {
        case .connected:
            Button("Disconnect") { sensor.disconnect(forget: false) }
            Button("Reconnect") { sensor.reconnect() }
        case .reconnecting, .failed:
            Button("Reconnect now") { sensor.reconnect() }
            Button("Scan for other sensors") { sensor.startScan() }
        case .idle:
            if sensor.hasPreferredSensor { Button("Connect to \(sensor.preferredName ?? "sensor")") { sensor.reconnect() } }
            Button("Scan") { sensor.startScan() }
        case .scanning:
            Button("Stop scanning") { sensor.stopScan() }
        case .connecting:
            Button("Cancel", role: .cancel) { sensor.disconnect(forget: false) }
        case .bluetoothOff:
            Text("Turn on Bluetooth in Control Center or Settings.").foregroundStyle(Theme.secondaryText)
        case .unauthorized:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        case .unsupported:
            Text("This device does not support Bluetooth LE.").foregroundStyle(Theme.secondaryText)
        }
    }
}

struct TipRow: View {
    var icon: String
    var text: String

    var body: some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.accent)
        }
    }
}
