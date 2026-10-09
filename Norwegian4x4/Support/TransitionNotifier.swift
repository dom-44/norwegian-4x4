import FourByFourCore
import UserNotifications

/// Backup lock-screen alerts for phase transitions.
///
/// These are *not* the source of truth: the workout state machine is. They
/// exist because iOS may suspend the app (for example when the heart-rate
/// sensor is not connected), in which case in-app audio cannot play. They are
/// scheduled only while the app is in the background and removed as soon as
/// it returns to the foreground or the workout is paused / ended.
@MainActor
final class TransitionNotifier {
    private let center = UNUserNotificationCenter.current()
    private static let prefix = "phase-"
    private(set) var authorized = false

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
    }

    func schedule(upcoming: [(phaseIndex: Int, date: Date)], plan: WorkoutPlan, maxHR: Int) {
        cancelAll()
        guard authorized else { return }
        // iOS allows 64 pending requests; a workout needs at most ~18.
        for item in upcoming.prefix(30) {
            let interval = item.date.timeIntervalSinceNow
            guard interval > 1 else { continue }
            let content = UNMutableNotificationContent()
            if item.phaseIndex < plan.phases.count {
                let phase = plan.phases[item.phaseIndex]
                content.title = phase.name
                if let target = HeartRateZones.target(for: phase.kind, maxHR: maxHR) {
                    content.body = "\(phase.summary) Target \(target.label) bpm."
                } else {
                    content.body = phase.summary
                }
            } else {
                content.title = "Workout complete"
                content.body = "Great work. Open the app to see your summary."
            }
            content.sound = .default
            content.interruptionLevel = .active
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            center.add(UNNotificationRequest(identifier: Self.prefix + String(item.phaseIndex), content: content, trigger: trigger))
        }
    }

    /// Synchronous so that a following `schedule` call cannot be undone by it.
    func cancelAll() {
        let identifiers = (0...40).map { Self.prefix + String($0) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
