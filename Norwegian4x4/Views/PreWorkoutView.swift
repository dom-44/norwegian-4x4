import FourByFourCore
import SwiftUI

struct PreWorkoutView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmNoSensor = false

    private var plan: WorkoutPlan { model.settings.workout.makePlan() }
    private var maxHR: Int { model.settings.heartRate.sanitizedMax }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryCard
                structureCard
                NavigationLink { SensorSetupView() } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        SensorStatusRow(state: model.sensor.state, battery: model.sensor.batteryLevel, signal: model.sensor.signal())
                    }
                    .card()
                }
                .buttonStyle(.plain)
                musicCard
                Button {
                    if model.sensor.state.isConnected { start() } else { confirmNoSensor = true }
                } label: {
                    Label("Start workout", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Ready?")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.sensor.activate()
            model.music.prepareAutoMix(force: false)
        }
        .confirmationDialog("No heart rate sensor connected", isPresented: $confirmNoSensor, titleVisibility: .visible) {
            Button("Start without heart rate") { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The timer and coaching work without a sensor, but no heart rate will be recorded. If a sensor connects later, recording starts automatically. Without a connected sensor iOS may suspend the app while the screen is locked; lock-screen alerts are then used for phase changes.")
        }
    }

    private func start() {
        model.workout.start()
    }

    private var summaryCard: some View {
        HStack {
            StatTile(title: "Total", value: Format.minutes(plan.totalDuration))
            StatTile(title: "Intervals", value: "\(model.settings.workout.intervalCount) × \(Format.minutes(model.settings.workout.interval))")
            StatTile(title: "HRmax", value: "\(maxHR)", unit: model.settings.heartRate.source == .ageEstimate ? "est." : "bpm")
        }
        .card()
    }

    private var structureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Structure").font(.headline)
            ForEach(plan.phases) { phase in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.color(for: phase.kind))
                        .frame(width: 6, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phase.name).font(.subheadline.weight(.semibold))
                        Text(targetText(phase)).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Text(Format.clock(phase.duration)).font(.subheadline.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    private func targetText(_ phase: PhaseDefinition) -> String {
        if let target = HeartRateZones.target(for: phase.kind, maxHR: maxHR) {
            return "Target \(target.label) bpm"
        }
        return phase.kind == .warmUp ? "Gradually increasing" : "Gradually decreasing"
    }

    @ViewBuilder private var musicCard: some View {
        let prefs = model.settings.music
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Music", systemImage: "music.note").font(.headline)
                Spacer()
                NavigationLink("Change") { MusicSettingsView() }.font(.subheadline)
            }
            switch prefs.provider {
            case .none:
                Text("No music. Coaching only.").foregroundStyle(Theme.secondaryText)
            case .manual:
                Text("Start your own music in any app. You'll hear a prompt when it's time to switch.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryText)
            case .spotify:
                Text("Spotify: \(model.music.spotify.status.label)").font(.subheadline).foregroundStyle(Theme.secondaryText)
                if prefs.autoMixEnabled {
                    AutoMixStatusView()
                }
                if model.music.effectivePreferences.warmUp != nil {
                    Button {
                        model.music.openSelection(for: .warmUp)
                    } label: {
                        Label(model.music.spotify.status == .connected ? "Play warm-up music" : "Connect Spotify & play warm-up", systemImage: "play.circle.fill")
                    }
                }
                Text("Tip: start playback before the workout. Spotify must be running for automatic switching.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            case .youtube:
                Text("YouTube can't be switched automatically. Open your warm-up music now; you'll get a prompt with an Open button at each change.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryText)
                if prefs.warmUp != nil {
                    Button { model.music.openSelection(for: .warmUp) } label: {
                        Label("Open warm-up music in YouTube", systemImage: "arrow.up.forward.app")
                    }
                }
            }
        }
        .card()
    }
}
