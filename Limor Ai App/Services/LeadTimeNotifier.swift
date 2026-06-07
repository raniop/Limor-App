import Foundation
import UserNotifications

extension UNNotificationSound {
    /// The user's chosen notification sound (a bundled `.caf` selected in
    /// Settings → התראות), or the system default when none is set. Used by
    /// every on-device notification Limor schedules so they all share one
    /// voice. Push notifications get the same sound server-side via the
    /// APNs `sound` field.
    static var limorChosen: UNNotificationSound {
        if let name = SharedStore.notificationSoundName, !name.isEmpty {
            return UNNotificationSound(named: UNNotificationSoundName(name))
        }
        return .default
    }
}

/// Schedules on-device "heads-up" notifications a fixed lead time (2h)
/// before each upcoming calendar meeting AND each pending reminder.
///
/// Pure-iOS (`UNUserNotificationCenter`) and deliberately *additive*:
///  • The backend already fires a reminder push at the exact due time —
///    this adds an earlier "in 2 hours" nudge so the user can prepare.
///  • `MeetingsNotifier` sends one evening digest of *tomorrow's* meetings —
///    this adds a per-meeting nudge 2h before each one actually starts.
///
/// Strategy mirrors `MeetingsNotifier`: cancel everything we own, then
/// register a fresh batch from the current calendar + reminders. Called on
/// every scene foreground so the schedule stays in step with new events,
/// edited reminders, and OS purges. iOS caps pending requests at 64, so we
/// bound each source to keep well under that alongside the other schedulers.
@MainActor
enum LeadTimeNotifier {

    private static let meetingPrefix = "limor.lead.meeting."
    private static let reminderPrefix = "limor.lead.reminder."

    /// How far before the event we nudge. Two hours, per product spec.
    private static let leadInterval: TimeInterval = 2 * 60 * 60

    private static let lookaheadDays = 7
    private static let maxMeetings = 20
    private static let maxReminders = 20

    /// Cancel our pending requests, then (if enabled + authorized) register a
    /// fresh batch for upcoming meetings and reminders. Idempotent.
    static func reschedule() async {
        await cancelAll()

        guard SharedStore.leadTimeNotifEnabled else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        guard allowed else { return }

        await scheduleMeetings(center: center)
        await scheduleReminders(center: center)
    }

    /// Drop every lead-time notification we've registered (both meetings and
    /// reminders). First step of `reschedule`, and called on toggle-off.
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix(meetingPrefix) || $0.identifier.hasPrefix(reminderPrefix) }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Meetings

    private static func scheduleMeetings(center: UNUserNotificationCenter) async {
        // Pull from every enabled source (EventKit + Google + Outlook/Graph)
        // so a calendar connected via the in-app Microsoft flow gets the same
        // 2h-before nudge as one wired into iOS Calendar.
        await CalendarAggregator.ensureAppleAccessIfNeeded()
        let events = await CalendarAggregator.upcomingEvents(daysAhead: lookaheadDays)
        guard !events.isEmpty else { return }

        let now = Date()
        var count = 0

        for ev in events {
            // All-day events have no meaningful "2 hours before" moment.
            guard !ev.is_all_day else { continue }
            guard let start = MeetingsCard.parseIso(ev.start_at) else { continue }

            let fire = start.addingTimeInterval(-leadInterval)
            guard fire > now else { continue } // Already inside the 2h window.
            if SharedStore.isWithinQuietHours(fire) { continue } // night-quiet

            let content = UNMutableNotificationContent()
            content.title = "בעוד שעתיים: \(ev.title)"
            var body = "הפגישה מתחילה ב-\(formatTime(start))"
            if let loc = ev.location, !loc.isEmpty {
                body += " · \(loc)"
            }
            content.body = body
            content.sound = .limorChosen
            // "תזכיר לי עוד שעה" action; lead_title lets the handler re-arm.
            content.categoryIdentifier = AppDelegate.leadMeetingCategoryId
            content.userInfo = ["lead_kind": "meeting", "lead_title": ev.title]

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "\(meetingPrefix)\(ev.event_id)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)

            count += 1
            if count >= maxMeetings { break }
        }
    }

    // MARK: - Reminders

    private static func scheduleReminders(center: UNUserNotificationCenter) async {
        // Pull the current pending reminders from the backend. The `token`
        // param is vestigial — APIClient attaches a fresh bearer itself.
        let reminders: [Reminder]
        do {
            reminders = try await APIClient.shared.listReminders(token: "", status: "pending")
        } catch {
            print("[lead] reminders fetch failed: \(error.localizedDescription)")
            return
        }

        let now = Date()
        var count = 0

        for r in reminders {
            let fire = r.dueDate.addingTimeInterval(-leadInterval)
            if SharedStore.isWithinQuietHours(fire) { continue } // night-quiet
            guard fire > now else { continue } // Due within 2h (or past) — the
            // backend's at-due-time push covers this; no early nudge to give.

            let content = UNMutableNotificationContent()
            content.title = "בעוד שעתיים: \(r.task)"
            content.body = "מועד התזכורת: \(formatTime(r.dueDate))"
            content.sound = .limorChosen
            // Lead category = "תזכיר לי עוד שעה" + "סמן כטופל". lead_title /
            // reminder_id let the snooze handler re-arm and still complete.
            content.categoryIdentifier = AppDelegate.leadReminderCategoryId
            content.userInfo = ["reminder_id": r.id, "lead_kind": "reminder", "lead_title": r.task]

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "\(reminderPrefix)\(r.id)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)

            count += 1
            if count >= maxReminders { break }
        }
    }

    // MARK: - Helpers

    private static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
