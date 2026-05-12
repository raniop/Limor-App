import Foundation
import UserNotifications

/// Schedules / un-schedules the user's recurring reminders via
/// `UNUserNotificationCenter`. One reminder × N selected weekdays = N
/// `UNCalendarNotificationTrigger`s, each repeating weekly. Paused
/// reminders are simply skipped on scheduling (no trigger registered).
///
/// Call `reschedule()` after any mutation to a reminder, and on every
/// scenePhase=.active so the user doesn't end up with stale state if
/// something gets nuked by iOS.
@MainActor
enum RecurringRemindersScheduler {

    /// Notification identifier prefix — anything with this prefix belongs
    /// to recurring reminders and can be safely cancelled wholesale on a
    /// re-schedule pass.
    private static let prefix = "limor.recur."

    /// Cancel everything we own + register fresh requests for the current
    /// (non-paused) reminders. Idempotent.
    static func reschedule() async {
        await cancelAll()

        let reminders = SharedStore.recurringReminders.filter { !$0.paused && !$0.daysOfWeek.isEmpty }
        guard !reminders.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        guard allowed else { return }

        for reminder in reminders {
            for weekday in reminder.daysOfWeek {
                let content = UNMutableNotificationContent()
                content.title = "⏰ \(reminder.task)"
                content.body = ""
                content.sound = .default

                var components = DateComponents()
                components.weekday = weekday
                components.hour = reminder.hour
                components.minute = reminder.minute

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                let id = "\(prefix)\(reminder.id.uuidString).\(weekday)"
                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    /// Drop every recurring-reminder notification we've registered. Called
    /// from `reschedule` as the first step, and when the user toggles a
    /// reminder to "paused" or deletes it (the scheduler reads from
    /// SharedStore so removing/toggling there + calling reschedule is enough).
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix(prefix) }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Request user notification authorization. Call this when the user
    /// first creates a recurring reminder — silent no-op if already
    /// granted/denied.
    static func ensureAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }
}
