import Charts
import FourByFourCore
import SwiftUI

/// Heart rate over workout time with target bands per phase. Lines are
/// broken where data is missing so gaps are visible instead of interpolated.
struct HeartRateChart: View {
    var samples: [HeartRateSample]
    var plan: WorkoutPlan
    var maxHR: Int

    private struct Point: Identifiable {
        let id: Int
        let minute: Double
        let bpm: Int
        let segment: Int
    }

    private struct Band: Identifiable {
        let id: Int
        let start: Double
        let end: Double
        let range: BPMRange
        let kind: PhaseKind
    }

    private var points: [Point] {
        let reduced = samples.count > 600 ? WorkoutStatistics.downsample(samples, bucket: 5) : samples.sorted { $0.t < $1.t }
        var segment = 0
        var previous: TimeInterval?
        return reduced.enumerated().map { index, sample in
            if let previous, sample.t - previous > WorkoutStatistics.gapThreshold + 5 { segment += 1 }
            previous = sample.t
            return Point(id: index, minute: sample.t / 60, bpm: sample.bpm, segment: segment)
        }
    }

    private var bands: [Band] {
        plan.phases.compactMap { phase in
            guard let range = HeartRateZones.target(for: phase.kind, maxHR: maxHR) else { return nil }
            let ts = samples.filter { $0.phaseIndex == phase.id }.map(\.t)
            guard let lo = ts.min(), let hi = ts.max(), hi > lo else { return nil }
            return Band(id: phase.id, start: lo / 60, end: hi / 60, range: range, kind: phase.kind)
        }
    }

    var body: some View {
        if samples.isEmpty {
            ContentUnavailableView("No heart rate data", systemImage: "heart.slash", description: Text("Connect a heart rate sensor before your next workout."))
                .frame(height: 200)
        } else {
            Chart {
                ForEach(bands) { band in
                    RectangleMark(
                        xStart: .value("Start", band.start),
                        xEnd: .value("End", band.end),
                        yStart: .value("Low", band.range.lower),
                        yEnd: .value("High", band.range.upper)
                    )
                    .foregroundStyle(Theme.color(for: band.kind).opacity(0.18))
                }
                ForEach(points) { point in
                    LineMark(
                        x: .value("Minute", point.minute),
                        y: .value("BPM", point.bpm),
                        series: .value("Segment", point.segment)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("bpm")
            .frame(height: 220)
            .accessibilityLabel("Heart rate graph")
        }
    }

    private var yDomain: ClosedRange<Int> {
        let bpms = samples.map(\.bpm)
        let low = min(bpms.min() ?? 60, HeartRateZones.bpm(percent: 55, of: maxHR))
        let high = max(bpms.max() ?? 180, HeartRateZones.bpm(percent: 98, of: maxHR))
        return (low - 5)...(high + 5)
    }
}
