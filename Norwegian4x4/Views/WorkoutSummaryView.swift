import FourByFourCore
import SwiftUI

struct WorkoutSummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var record: WorkoutRecord
    var isPostWorkout: Bool

    private var summary: WorkoutSummary { record.summary }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                if let error = model.workout.saveError, isPostWorkout {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                }
                statsGrid
                VStack(alignment: .leading, spacing: 8) {
                    Text("Heart rate").font(.headline)
                    HeartRateChart(samples: record.samples, plan: record.plan, maxHR: record.maxHeartRate)
                }
                .card()
                intervalsCard
                recoveryCard
                dataQualityCard
                Text("Targets based on HRmax \(record.maxHeartRate) bpm. Zones are training estimates, not medical advice.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
            .padding()
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(isPostWorkout ? "Summary" : record.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPostWorkout {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.workout.dismissSummary() }.font(.headline)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: record.completed ? "checkmark.seal.fill" : "flag.checkered")
                .font(.system(size: 44))
                .foregroundStyle(record.completed ? .green : .orange)
            Text(record.completed ? "Workout complete" : "Workout ended early")
                .font(.title.weight(.heavy))
            Text(record.startedAt.formatted(date: .complete, time: .shortened))
                .font(.subheadline).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var statsGrid: some View {
        VStack(spacing: 14) {
            HStack {
                StatTile(title: "Duration", value: Format.clock(summary.activeDuration), systemImage: "timer")
                StatTile(title: "Time in target", value: Format.clock(summary.timeInTarget), systemImage: "scope")
            }
            HStack {
                StatTile(title: "Average", value: summary.averageBPM.map(String.init) ?? "—", unit: "bpm", systemImage: "heart")
                StatTile(title: "Maximum", value: summary.maxBPM.map(String.init) ?? "—", unit: "bpm", systemImage: "heart.fill")
            }
            HStack {
                StatTile(title: "Target share", value: Format.percent(summary.timeInTargetFraction), systemImage: "chart.pie")
                StatTile(title: "Interval avg", value: WorkoutStatisticsDisplay.intervalAverage(summary), unit: "bpm", systemImage: "bolt.heart")
            }
        }
        .card()
    }

    private var intervalsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Intervals").font(.headline)
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("Avg").frame(width: 48)
                Text("Max").frame(width: 48)
                Text("In zone").frame(width: 64)
                Text("Reach").frame(width: 56)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            ForEach(summary.intervals) { phase in
                HStack {
                    Text(phase.name + (phase.skipped ? " *" : ""))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(phase.averageBPM.map(String.init) ?? "—").frame(width: 48)
                    Text(phase.maxBPM.map(String.init) ?? "—").frame(width: 48)
                    Text(Format.clock(phase.timeInTarget)).frame(width: 64)
                    Text(phase.timeToTarget.map { Format.clock($0) } ?? "—").frame(width: 56)
                }
                .font(.subheadline.monospacedDigit())
                .accessibilityElement(children: .combine)
            }
            Text("Reach = time from interval start until heart rate entered the target zone (heart-rate response).")
                .font(.caption2).foregroundStyle(Theme.secondaryText)
        }
        .card()
    }

    @ViewBuilder private var recoveryCard: some View {
        let recoveries = summary.phases.filter { $0.kind == .recovery }
        if !recoveries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recovery").font(.headline)
                ForEach(recoveries) { phase in
                    HStack {
                        Text(phase.name).frame(maxWidth: .infinity, alignment: .leading)
                        Text("avg \(phase.averageBPM.map(String.init) ?? "—")")
                        Text(phase.recoveryDrop60s.map { "−\($0) bpm / 60 s" } ?? "—")
                            .frame(width: 120, alignment: .trailing)
                    }
                    .font(.subheadline.monospacedDigit())
                }
                Text("Heart-rate drop in the first 60 s of recovery. A larger drop usually indicates better fitness.")
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            .card()
        }
    }

    private var dataQualityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Data quality").font(.headline)
            if summary.gaps.isEmpty && summary.sampleCount > 0 {
                Label("Continuous heart rate data", systemImage: "checkmark.circle").foregroundStyle(.green)
            } else if summary.sampleCount == 0 {
                Label("No heart rate recorded", systemImage: "heart.slash").foregroundStyle(.orange)
            } else {
                Label("\(summary.gaps.count) gap\(summary.gaps.count == 1 ? "" : "s") · \(Format.clock(summary.totalGapDuration)) without data", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                ForEach(Array(summary.gaps.prefix(6).enumerated()), id: \.offset) { _, gap in
                    Text("\(Format.clock(gap.start)) – \(Format.clock(gap.end))")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
            }
            if summary.phases.contains(where: \.skipped) {
                Text("* Phase passed while the app was suspended or closed.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            if let sensor = record.sensorName {
                Text("Sensor: \(sensor)").font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .font(.subheadline)
        .card()
    }
}

enum WorkoutStatisticsDisplay {
    static func intervalAverage(_ summary: WorkoutSummary) -> String {
        let values = summary.intervals.compactMap(\.averageBPM)
        guard !values.isEmpty else { return "—" }
        return String(Int((Double(values.reduce(0, +)) / Double(values.count)).rounded()))
    }
}
