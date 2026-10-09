import FourByFourCore
import UIKit

/// Haptics only play while the app is in the foreground (iOS restriction).
@MainActor
enum Haptics {
    private static let notification = UINotificationFeedbackGenerator()
    private static let impact = UIImpactFeedbackGenerator(style: .rigid)

    static func play(_ cue: HapticCue) {
        switch cue {
        case .phaseChange:
            notification.notificationOccurred(.warning)
        case .countdownTick:
            impact.impactOccurred(intensity: 0.8)
        case .completed:
            notification.notificationOccurred(.success)
        }
    }

    static func tap() {
        impact.impactOccurred(intensity: 0.5)
    }
}
