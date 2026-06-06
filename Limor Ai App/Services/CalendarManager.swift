import EventKit
import Foundation

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    private let store = EKEventStore()
    @Published private(set) var hasAccess = false

    /// iOS 17+ split read/write into separate permissions. We ask for full access
    /// because the chat tools need to be able to *write* events later (read-only
    /// would limit `today_events` etc. fine but blocks `create_event`).
    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            hasAccess = granted
            return granted
        } catch {
            hasAccess = false
            return false
        }
    }

    /// Fetch events from now through `daysAhead` calendar days, across all calendars
    /// the user has authorized. Skips fetched-but-unidentifiable events.
    /// When `SharedStore.hideBirthdayEvents` is true (default), filters out
    /// iOS's auto-generated birthday calendar entries so they don't bury
    /// real meetings on the home card.
    func fetchUpcomingEvents(daysAhead: Int = 60) -> [CalendarEventDTO] {
        guard hasAccess else { return [] }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) else {
            return []
        }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        let formatter = ISO8601DateFormatter.limor
        let hideBirthdays = SharedStore.hideBirthdayEvents

        return events.compactMap { event -> CalendarEventDTO? in
            guard let identifier = event.eventIdentifier, !identifier.isEmpty else { return nil }
            if hideBirthdays, Self.isBirthdayEvent(event) { return nil }
            return CalendarEventDTO(
                event_id: identifier,
                title: event.title?.isEmpty == false ? event.title : "(ללא כותרת)",
                notes: event.notes?.isEmpty == false ? event.notes : nil,
                location: event.location?.isEmpty == false ? event.location : nil,
                start_at: formatter.string(from: event.startDate),
                end_at: formatter.string(from: event.endDate),
                is_all_day: event.isAllDay,
                calendar_name: event.calendar?.title
            )
        }
    }

    /// Two ways an event can be a birthday:
    /// - It lives in the iOS-managed Birthdays calendar
    ///   (`EKCalendarType.birthday`).
    /// - It's an explicit birthday entry the user / Contacts created
    ///   (`birthdayContactIdentifier` is non-nil).
    private static func isBirthdayEvent(_ event: EKEvent) -> Bool {
        if event.calendar?.type == .birthday { return true }
        if event.birthdayContactIdentifier?.isEmpty == false { return true }
        return false
    }

    // MARK: - Reminder → Calendar Event mirror
    //
    // Limor reminders mirror to *both* Apple Reminders (`RemindersWriter`)
    // and Apple Calendar — the latter so a reminder at 09:00 shows up
    // alongside meetings on the user's calendar view, not just as a
    // checklist row in Reminders.app. Each Limor reminder maps to a single
    // 30-minute EKEvent. Tracking lives in `SharedStore.syncedReminderEventIds`
    // (parallel to the existing `syncedReminderEkIds` for the Reminders side).

    private static let mirroredEventDuration: TimeInterval = 30 * 60

    /// First writable calendar on the device, preferring the user's default
    /// for new events. Falls back to any non-birthday/subscription calendar
    /// if `defaultCalendarForNewEvents` is nil (rare, but possible when the
    /// user has only read-only calendars).
    private func chosenWritableCalendar() -> EKCalendar? {
        if let def = store.defaultCalendarForNewEvents, def.allowsContentModifications {
            return def
        }
        return store.calendars(for: .event)
            .first { $0.allowsContentModifications && $0.type != .birthday }
    }

    /// Create an EKEvent for the given Limor reminder unless one already
    /// exists for it on this device. Idempotent — safe to call repeatedly
    /// from `mirrorAll`-style sync paths. No-op if calendar access hasn't
    /// been granted (the chat tools depend on the same permission, so by
    /// the time the user is creating reminders they've usually approved).
    func writeReminderAsEventIfNeeded(reminderId: String, task: String, dueAt: Date) async {
        if SharedStore.syncedReminderEventIds[reminderId] != nil { return }
        if !hasAccess {
            let granted = await requestAccess()
            if !granted { return }
        }
        guard let calendar = chosenWritableCalendar() else { return }

        let event = EKEvent(eventStore: store)
        event.title = task
        event.startDate = dueAt
        event.endDate = dueAt.addingTimeInterval(Self.mirroredEventDuration)
        event.calendar = calendar
        // Mark the event with a note so users (and future-us) can see why
        // a non-meeting entry is on the calendar.
        event.notes = "נוצר על ידי לימור מתוך תזכורת."
        do {
            try store.save(event, span: .thisEvent, commit: true)
            if let id = event.eventIdentifier {
                var map = SharedStore.syncedReminderEventIds
                map[reminderId] = id
                SharedStore.syncedReminderEventIds = map
            }
        } catch {
            print("[calendar-write] failed: \(error.localizedDescription)")
        }
    }

    /// Bulk mirror for the reminders list — drops any pending reminder that
    /// doesn't already have a matching calendar event. Mirrors the shape of
    /// `RemindersWriter.mirrorAll`.
    func mirrorRemindersAsEvents(_ reminders: [Reminder]) async {
        for r in reminders where r.status == .pending {
            await writeReminderAsEventIfNeeded(
                reminderId: r.id, task: r.task, dueAt: r.dueDate
            )
        }
    }

    /// Drop the mirrored EKEvent so a deleted Limor reminder doesn't leave
    /// an orphan block on the user's calendar. Mirrors
    /// `RemindersWriter.delete`.
    func deleteReminderEvent(reminderId: String) async {
        guard let eventId = SharedStore.syncedReminderEventIds[reminderId] else { return }
        if !hasAccess {
            let granted = await requestAccess()
            if !granted { return }
        }
        defer {
            var map = SharedStore.syncedReminderEventIds
            map.removeValue(forKey: reminderId)
            SharedStore.syncedReminderEventIds = map
        }
        guard let event = store.event(withIdentifier: eventId) else { return }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            print("[calendar-write] delete failed: \(error.localizedDescription)")
        }
    }
}
