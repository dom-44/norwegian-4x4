import FourByFourCore
import SwiftUI

struct ProgressRing: View {
    var fraction: Double
    var color: Color
    var lineWidth: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: fraction)
        }
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var unit: String? = nil
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.weight(.bold).monospacedDigit())
                if let unit { Text(unit).font(.caption).foregroundStyle(Theme.secondaryText) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Zone indicator using color, icon and text together (not color alone).
struct ZoneBadge: View {
    var zone: ZoneStatus
    var large = false

    var body: some View {
        Label(Theme.label(for: zone), systemImage: Theme.icon(for: zone))
            .font(large ? .headline : .subheadline.weight(.semibold))
            .foregroundStyle(Theme.color(for: zone))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.color(for: zone).opacity(0.15), in: Capsule())
            .accessibilityLabel("Heart rate zone: \(Theme.label(for: zone))")
    }
}

struct SensorStatusRow: View {
    var state: SensorConnectionState
    var battery: Int?
    var signal: HeartRateSignal.State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.label).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if let bpm = signal.liveBPM {
                Text("\(bpm)").font(.title2.weight(.bold).monospacedDigit())
                Image(systemName: "heart.fill").foregroundStyle(Theme.accent).symbolEffect(.pulse)
            }
        }
    }

    private var icon: String {
        switch state {
        case .connected: return "heart.circle.fill"
        case .scanning, .connecting, .reconnecting: return "antenna.radiowaves.left.and.right"
        default: return "heart.slash.circle"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return signal.liveBPM != nil ? .green : .yellow
        case .scanning, .connecting, .reconnecting: return .yellow
        default: return .gray
        }
    }

    private var detail: String {
        switch signal {
        case .live:
            return battery.map { "Live · Battery \($0)%" } ?? "Live"
        case .noContact:
            return "No skin contact — moisten the strap electrodes"
        case .stale(_, let age):
            return state.isConnected ? "Waiting for data (\(Int(age)) s)" : "Heart rate unavailable"
        case .unavailable:
            return state.isConnected ? "Waiting for data…" : "Tap to set up your Polar H10"
        }
    }
}
