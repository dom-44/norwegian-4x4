import FourByFourCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDeleteHistory = false
    @State private var confirmReset = false
    @State private var healthError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            heartRateSection(model: model)
            workoutSection(model: model)

            Section("Coaching") {
                Toggle("Voice coaching", isOn: $model.settings.coaching.voiceEnabled)
                Toggle("Phase announcements", isOn: $model.settings.coaching.phaseAnnouncements)
                    .disabled(!model.settings.coaching.voiceEnabled)
                Toggle("Midpoint reminders", isOn: $model.settings.coaching.midpointReminders)
                    .disabled(!model.settings.coaching.voiceEnabled)
                Toggle("Final 10-second countdown", isOn: $model.settings.coaching.finalCountdown)
                Toggle("Transition sounds", isOn: $model.settings.coaching.transitionSounds)
                Toggle("Haptics", isOn: $model.settings.coaching.haptics)
                VStack(alignment: .leading) {
                    Text("Speech rate")
                    Slider(value: $model.settings.coaching.speechRate, in: 0.35...0.6)
                }
                NavigationLink("Sounds per phase") { TransitionStylesView() }
                Button("Preview voice") {
                    CoachingPreview.speak(CoachingScript.startLine(phase: WorkoutPlan.standard.phases[1], maxHR: model.settings.heartRate.sanitizedMax),
                                          rate: model.settings.coaching.speechRate)
                }
            }

            Section {
                Toggle("Lock-screen alerts", isOn: $model.settings.coaching.lockScreenAlerts)
                Toggle("Keep screen awake during workout", isOn: $model.settings.keepScreenAwake)
            } header: {
                Text("Background")
            } footer: {
                Text("Lock-screen alerts are a backup for phase changes if iOS suspends the app (for example when no sensor is connected). The workout timer itself never depends on them.")
            }

            Section("Connections") {
                NavigationLink("Heart rate sensor") { SensorSetupView() }
                NavigationLink("Music") { MusicSettingsView() }
            }

            healthSection(model: model)

            Section {
                Button("Delete all workout history", role: .destructive) { confirmDeleteHistory = true }
                Button("Reset all settings", role: .destructive) { confirmReset = true }
            } header: {
                Text("Data")
            } footer: {
                Text("All data is stored only on this iPhone. Nothing is uploaded; there are no accounts, analytics or ads.")
            }

            Section("About") {
                Text("Heart rate targets are calculated from your configured maximum heart rate and are training estimates, not medical advice. Consult a doctor before starting high-intensity training if you have any health concerns.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .confirmationDialog("Delete all workouts?", isPresented: $confirmDeleteHistory, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { model.deleteAllHistory() }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.resetSettings() }
        } message: {
            Text("Workout durations, heart rate, coaching and music settings return to defaults. History and the paired sensor are kept.")
        }
    }

    // MARK: Heart rate

    private func healthSection(model: AppModel) -> some View {
        let health = model.settings.health ?? HealthSettings()
        return Section {
            Toggle("Save workouts to Apple Health", isOn: Binding {
                health.enabled
            } set: { on in
                healthError = nil
                guard on else { model.settings.health?.enabled = false; return }
                Task {
                    // Shows the Health permission sheet the first time.
                    switch await model.health.requestAuthorization() {
                    case .success:
                        var updated = model.settings.health ?? HealthSettings()
                        updated.enabled = true
                        model.settings.health = updated
                    case .failure(let error):
                        healthError = error.localizedDescription
                    }
                }
            })
            if health.enabled {
                Picker("Workout type", selection: Binding {
                    health.activity
                } set: { activity in
                    model.settings.health?.activity = activity
                }) {
                    ForEach(HealthActivity.allCases) { Text($0.displayName).tag($0) }
                }
            }
            if let healthError {
                Text(healthError).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text("After each workout: a workout entry with your heart-rate curve, plus estimated active energy if your weight, age and sex are set in Health. If saving is denied, change it in Settings › Health › Data Access & Devices.")
        }
    }

    @ViewBuilder
    private func heartRateSection(model: AppModel) -> some View {
        let profile = model.settings.heartRate
        Section {
            Toggle("Estimate from age", isOn: Binding(
                get: { profile.source == .ageEstimate },
                set: { useAge in
                    model.settings.heartRate = useAge
                        ? .estimated(age: profile.age ?? 40)
                        : HeartRateProfile(maxHeartRate: profile.maxHeartRate, source: .manual, age: profile.age)
                }
            ))
            if profile.source == .ageEstimate {
                Stepper(value: Binding(
                    get: { profile.age ?? 40 },
                    set: { model.settings.heartRate = .estimated(age: $0) }
                ), in: HeartRateProfile.validAgeRange) {
                    LabeledContent("Age", value: "\(profile.age ?? 40)")
                }
                LabeledContent("Estimated HRmax", value: "\(profile.maxHeartRate) bpm")
            } else {
                Stepper(value: Binding(
                    get: { profile.maxHeartRate },
                    set: { model.settings.heartRate = HeartRateProfile(maxHeartRate: $0, source: .manual, age: profile.age) }
                ), in: HeartRateProfile.validMaxRange) {
                    LabeledContent("Max heart rate", value: "\(profile.maxHeartRate) bpm")
                }
            }
            let hr = profile.sanitizedMax
            if let high = HeartRateZones.target(for: .interval, maxHR: hr), let low = HeartRateZones.target(for: .recovery, maxHR: hr) {
                LabeledContent("Intervals (85–95%)", value: "\(high.label) bpm")
                LabeledContent("Recovery (60–70%)", value: "\(low.label) bpm")
            }
        } header: {
            Text("Heart rate")
        } footer: {
            Text(profile.source == .ageEstimate
                 ? "220 − age is a rough population estimate; your real maximum may differ by 10–20 bpm. If you know your measured maximum, enter it manually."
                 : "Use a measured maximum (e.g. the highest value seen in a hard all-out effort) for the most accurate zones.")
        }
    }

    // MARK: Workout

    @ViewBuilder
    private func workoutSection(model: AppModel) -> some View {
        @Bindable var model = model
        let config = model.settings.workout
        Section {
            DurationStepper(title: "Warm-up", value: $model.settings.workout.warmUp, range: WorkoutConfiguration.warmUpRange, step: 60)
            DurationStepper(title: "Interval", value: $model.settings.workout.interval, range: WorkoutConfiguration.intervalRange, step: 30)
            DurationStepper(title: "Recovery", value: $model.settings.workout.recovery, range: WorkoutConfiguration.recoveryRange, step: 30)
            Stepper(value: $model.settings.workout.intervalCount, in: WorkoutConfiguration.intervalCountRange) {
                LabeledContent("Intervals", value: "\(config.intervalCount)")
            }
            DurationStepper(title: "Cool-down", value: $model.settings.workout.coolDown, range: WorkoutConfiguration.coolDownRange, step: 60)
            LabeledContent("Total", value: Format.minutes(config.makePlan().totalDuration))
            Button("Restore standard 4x4 (40 min)") { model.settings.workout = .standard }
                .disabled(config.isStandard)
        } header: {
            Text("Workout")
        } footer: {
            Text("Standard: 10 min warm-up, 4 × 4 min at 85–95% HRmax with 3 min active recovery, 5 min cool-down.")
        }
    }
}

struct DurationStepper: View {
    var title: String
    @Binding var value: TimeInterval
    var range: ClosedRange<TimeInterval>
    var step: TimeInterval

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            LabeledContent(title, value: Format.clock(value))
        }
    }
}

struct TransitionStylesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(PhaseKind.allCases, id: \.self) { kind in
                Section(kind.displayName) {
                    Picker("Sound", selection: Binding(
                        get: { model.settings.coaching[kind].tone },
                        set: { model.settings.coaching[kind].tone = $0 }
                    )) {
                        ForEach(TransitionTone.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Haptic", isOn: Binding(
                        get: { model.settings.coaching[kind].haptic },
                        set: { model.settings.coaching[kind].haptic = $0 }
                    ))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Sounds per phase")
    }
}
