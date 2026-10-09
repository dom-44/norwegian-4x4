import Charts
import FourByFourCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: WorkoutOverview?

    var body: some View {
        List {
            if model.history.isEmpty {
                ContentUnavailableView("No workouts yet", systemImage: "figure.run", description: Text("Completed workouts are stored only on this iPhone."))
                    .listRowBackground(Color.clear)
            } else {
                Section { trends }
                Section("Workouts") {
                    ForEach(model.history) { overview in
                        NavigationLink {
                            HistoryDetailLoader(id: overview.id)
                        } label: {
                            HistoryRow(overview: overview)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = overview }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("History")
        .confirmationDialog("Delete this workout?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id { model.deleteWorkout(id: id) }
                pendingDelete = nil
            }
        }
    }

    @ViewBuilder private var trends: some View {
        let trend = HistoryTrend.compute(model.history)
        let recent = Array(model.history.filter(\.completed).prefix(12).reversed())
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                StatTile(title: "Workouts", value: "\(trend.workoutCount)")
                StatTile(title: "Avg in target", value: trend.averageTimeInTargetFraction.map(Format.percent) ?? "—")
                StatTile(title: "Interval HR", value: trend.intervalBPMChange.map { $0 >= 0 ? "+\($0)" : "\($0)" } ?? "—", unit: trend.intervalBPMChange == nil ? nil : "bpm")
            }
            if recent.count >= 2 {
                Text("Time in target zone (last \(recent.count))").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                Chart(recent) { overview in
                    BarMark(
                        x: .value("Date", overview.startedAt, unit: .day),
                        y: .value("In target", overview.timeInTargetFraction * 100)
                    )
                    .foregroundStyle(Theme.accent.gradient)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(values: [0, 50, 100]) }
                .frame(height: 140)
                if recent.contains(where: { $0.intervalAverageBPM != nil }) {
                    Text("Average interval heart rate").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Chart(recent.filter { $0.intervalAverageBPM != nil }) { overview in
                        LineMark(x: .value("Date", overview.startedAt, unit: .day), y: .value("bpm", overview.intervalAverageBPM ?? 0))
                            .symbol(.circle)
                            .foregroundStyle(Theme.color(for: .recovery))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 120)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct HistoryRow: View {
    var overview: WorkoutOverview

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(overview.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                Text(overview.completed ? "Completed" : "Ended early")
                    .font(.caption)
                    .foregroundStyle(overview.completed ? .green : .orange)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.clock(overview.activeDuration)).font(.subheadline.monospacedDigit())
                Text("\(overview.averageBPM.map { "\($0) bpm avg" } ?? "no HR") · \(Format.percent(overview.timeInTargetFraction)) in zone")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
