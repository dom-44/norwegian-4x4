import FourByFourCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                NavigationLink {
                    PreWorkoutView()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Norwegian 4x4")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.vertical, 4)

                NavigationLink {
                    SensorSetupView()
                } label: {
                    // Re-evaluated every second so a stale reading is never shown as live.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        SensorStatusRow(state: model.sensor.state, battery: model.sensor.batteryLevel, signal: model.sensor.signal())
                    }
                    .card()
                }
                .buttonStyle(.plain)

                if let last = model.lastWorkout {
                    NavigationLink {
                        HistoryDetailLoader(id: last.id)
                    } label: {
                        LastWorkoutCard(overview: last)
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink {
                    MusicSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.title2).foregroundStyle(Theme.accent).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Music").font(.headline)
                            Text(musicSubtitle).font(.subheadline).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.secondaryText)
                    }
                    .card()
                }
                .buttonStyle(.plain)

                HStack(spacing: 12) {
                    NavigationLink { HistoryView() } label: {
                        Label("History", systemImage: "chart.xyaxis.line").frame(maxWidth: .infinity).card()
                    }
                    NavigationLink { SettingsView() } label: {
                        Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity).card()
                    }
                }
                .buttonStyle(.plain)
                .font(.headline)

                Text("Heart rate zones are estimates for training guidance, not medical advice.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Norwegian 4x4")
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Norwegian 4x4")
                .font(.largeTitle.weight(.heavy))
            Text("\(Format.minutes(model.settings.workout.makePlan().totalDuration)) · \(model.settings.workout.intervalCount) × \(Format.minutes(model.settings.workout.interval)) at 85–95% HRmax")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var musicSubtitle: String {
        let prefs = model.settings.music
        switch prefs.provider {
        case .none: return "No music"
        case .manual: return "Manual — use any music app"
        case .spotify: return "Spotify · \(model.music.spotify.status.label)"
        case .youtube: return "YouTube · opens the official app"
        }
    }
}

struct LastWorkoutCard: View {
    var overview: WorkoutOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last workout").font(.headline)
                Spacer()
                Text(overview.startedAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.subheadline).foregroundStyle(Theme.secondaryText)
                if !overview.completed {
                    Text("Ended early").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            HStack {
                StatTile(title: "Duration", value: Format.clock(overview.activeDuration))
                StatTile(title: "Avg HR", value: overview.averageBPM.map(String.init) ?? "—", unit: "bpm")
                StatTile(title: "In target", value: Format.percent(overview.timeInTargetFraction))
            }
        }
        .card()
    }
}

/// Loads a full record from disk for display.
struct HistoryDetailLoader: View {
    @Environment(AppModel.self) private var model
    var id: UUID

    var body: some View {
        if let record = model.historyStore.record(id: id) {
            WorkoutSummaryView(record: record, isPostWorkout: false)
        } else {
            ContentUnavailableView("Workout not found", systemImage: "exclamationmark.triangle")
        }
    }
}
