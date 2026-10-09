import FourByFourCore
import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.29)
    static let background = Color(red: 0.05, green: 0.055, blue: 0.075)
    static let card = Color.white.opacity(0.07)
    static let cardStroke = Color.white.opacity(0.08)
    static let secondaryText = Color.white.opacity(0.6)

    static func color(for kind: PhaseKind) -> Color {
        switch kind {
        case .warmUp: return Color(red: 1.0, green: 0.78, blue: 0.3)
        case .interval: return accent
        case .recovery: return Color(red: 0.25, green: 0.78, blue: 0.85)
        case .coolDown: return Color(red: 0.62, green: 0.55, blue: 1.0)
        }
    }

    static func color(for zone: ZoneStatus) -> Color {
        switch zone {
        case .below: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .within: return Color(red: 0.3, green: 0.85, blue: 0.45)
        case .above: return Color(red: 1.0, green: 0.3, blue: 0.3)
        case .unavailable: return .gray
        case .noTarget: return .white
        }
    }

    static func icon(for zone: ZoneStatus) -> String {
        switch zone {
        case .below: return "arrow.up.circle.fill"
        case .within: return "checkmark.circle.fill"
        case .above: return "arrow.down.circle.fill"
        case .unavailable: return "heart.slash.fill"
        case .noTarget: return "heart.fill"
        }
    }

    static func label(for zone: ZoneStatus) -> String {
        switch zone {
        case .below: return "Below target"
        case .within: return "In target"
        case .above: return "Above target"
        case .unavailable: return "No heart rate"
        case .noTarget: return "No target zone"
        }
    }
}

enum Format {
    /// m:ss (or h:mm:ss).
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Countdown display rounds up so "0:00" only shows at the very end.
    static func countdown(_ seconds: TimeInterval) -> String {
        clock(seconds.rounded(.up))
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total % 60 == 0 { return "\(total / 60) min" }
        return String(format: "%d:%02d min", total / 60, total % 60)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.cardStroke))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
