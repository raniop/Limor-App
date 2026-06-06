import Foundation
import UserNotifications

/// Schedules a daily LOCAL push notification listing the user's meetings
/// for the *following* day. Pure-iOS — uses `UNUserNotificationCenter` and
/// `CalendarManager` (EventKit), no backend involvement. This is on
/// purpose: the existing `morning_brief` / `evening_recap` push paths are
/// server-fired and depend on calendar events being uploaded; this one
/// works offline, on any device the user happens to be on.
///
/// Strategy: pre-schedule the next 7 days at once. iOS allows up to 64
/// pending requests so 7 is comfortable, and 7 means the user gets
/// notifications for a week even if they never re-open the app. We refresh
/// on every scene foreground so the content stays fresh as new events get
/// added.
@MainActor
enum MeetingsNotifier {

    private static let identifierPrefix = "limor.meetings.tomorrow."
    private static let lookaheadDays = 7

    /// Cancel any previously-pending requests, then (if the user has the
    /// toggle on AND iOS notifications are authorized AND calendar access
    /// was granted) schedule a fresh batch. Safe to call repeatedly.
    static func reschedule() async {
        await cancelAll()

        guard SharedStore.meetingsNotifEnabled else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        guard allowed else { return }

        // Calendar access — silently bail if missing. The user gets a UI hint
        // about this in NotificationsSettingsView, so no need to surface a
        // log line here.
        guard CalendarManager.shared.hasAccess else { return }

        let hour = SharedStore.meetingsNotifHour
        let minute = SharedStore.meetingsNotifMinute
        let cal = Calendar.current
        let now = Date()

        // Compute today's notification fire time. If it's already past, start
        // from tomorrow so we don't fire immediately.
        var firstComponents = cal.dateComponents([.year, .month, .day], from: now)
        firstComponents.hour = hour
        firstComponents.minute = minute
        firstComponents.second = 0
        guard var firstFire = cal.date(from: firstComponents) else { return }
        if firstFire <= now {
            firstFire = cal.date(byAdding: .day, value: 1, to: firstFire) ?? firstFire
        }

        // Fetch a wide-enough window once.
        let allEvents = CalendarManager.shared.fetchUpcomingEvents(daysAhead: lookaheadDays + 2)

        for offset in 0..<lookaheadDays {
            guard let fireDate = cal.date(byAdding: .day, value: offset, to: firstFire) else { continue }
            // "Tomorrow" relative to when the notification fires.
            guard let targetDay = cal.date(byAdding: .day, value: 1, to: fireDate) else { continue }

            let dayEvents = events(forDay: targetDay, in: allEvents, calendar: cal)
            guard !dayEvents.isEmpty else { continue } // Skip empty days

            let content = makeContent(for: dayEvents, day: targetDay, calendar: cal)
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "\(identifierPrefix)\(offset)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    /// Cancel ALL pending meetings notifications. Called both from
    /// `reschedule` (as the first step) and on toggle-off.
    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
            .map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Helpers

    private static func events(
        forDay day: Date,
        in pool: [CalendarEventDTO],
        calendar cal: Calendar
    ) -> [CalendarEventDTO] {
        let startOfDay = cal.startOfDay(for: day)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
        return pool
            .compactMap { ev -> (Date, CalendarEventDTO)? in
                guard let start = MeetingsCard.parseIso(ev.start_at) else { return nil }
                return (start >= startOfDay && start < endOfDay) ? (start, ev) : nil
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    private static func makeContent(
        for events: [CalendarEventDTO],
        day: Date,
        calendar cal: Calendar
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let label = dayLabel(for: day, calendar: cal)
        content.title = "📅 הפגישות שלך \(label)"

        let lines = events.prefix(5).map { ev -> String in
            if ev.is_all_day {
                return "• \(ev.title)"
            }
            let time = MeetingsCard.parseIso(ev.start_at).map(formatTime) ?? ""
            return "• \(time) — \(ev.title)"
        }
        var body = lines.joined(separator: "\n")
        if events.count > 5 {
            body += "\n+ ועוד \(events.count - 5)"
        }
        content.body = body
        content.sound = .limorChosen
        return content
    }

    private static func dayLabel(for date: Date, calendar cal: Calendar) -> String {
        if cal.isDateInTomorrow(date) { return "מחר" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "EEEE"
        return "ב" + f.string(from: date)
    }

    private static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
