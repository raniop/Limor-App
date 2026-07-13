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
                title: event.title?.isEmpty == false ? event.title : tr("(ללא כותרת)", "(Untitled)"),
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
        event.notes = tr("נוצר על ידי לימור מתוך תזכורת.", "Created by Limor from a reminder.")
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

    /// Create a calendar event that blocks time (Limor's `create_event` tool,
    /// delivered via silent push). Distinct from a reminder — this is a real
    /// EKEvent with a start + end + optional location. Returns true on success.
    @discardableResult
    func createEvent(title: String, start: Date, end: Date, location: String?) async -> Bool {
        if !hasAccess {
            let granted = await requestAccess()
            if !granted { return false }
        }
        guard let calendar = chosenWritableCalendar() else { return false }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end > start ? end : start.addingTimeInterval(60 * 60)
        if let location, !location.trimmingCharacters(in: .whitespaces).isEmpty {
            event.location = location
        }
        event.calendar = calendar
        event.notes = tr("נוצר על ידי לימור.", "Created by Limor.")
        do {
            try store.save(event, span: .thisEvent, commit: true)
            print("[calendar-write] created event '\(title)' at \(start)")
            return true
        } catch {
            print("[calendar-write] create event failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Create a create_event item guarding against duplicates by its stable
    /// `eventId`. Safe to call from BOTH the silent push and the outbox drain —
    /// the first call wins, the second is a no-op. Returns true if the event now
    /// exists on the device (created just now OR already created earlier).
    ///
    /// When `attendees` is non-empty the event is created in the user's GOOGLE
    /// calendar instead of EventKit — Google emails a real invitation to each
    /// attendee (EventKit attendees are read-only, so it can't send invites).
    /// If the Google write scope isn't granted / Google isn't connected, we
    /// fall back to a local EKEvent WITHOUT invites so the slot isn't lost.
    @MainActor @discardableResult
    func createTrackedEvent(eventId: String, title: String, start: Date, end: Date, location: String?, attendees: [String]? = nil) async -> Bool {
        if SharedStore.createdCalendarEventIds.contains(eventId) { return true }
        // Reserve the id BEFORE the async write so a concurrent caller (push vs
        // drain) can't pass the check and create a duplicate. This read-modify-
        // write runs synchronously on the main actor, so it's atomic.
        var ids = SharedStore.createdCalendarEventIds
        ids.insert(eventId)
        SharedStore.createdCalendarEventIds = ids

        var ok = false
        if let attendees, !attendees.isEmpty {
            do {
                try await GoogleAPIs.createEventWithInvites(
                    title: title, start: start, end: end, location: location, attendees: attendees
                )
                ok = true
                print("[calendar-write] Google event '\(title)' with \(attendees.count) invite(s)")
                // No EKEvent on purpose — the Google calendar syncs to the
                // iPhone's Calendar app on its own; a second EKEvent would
                // show as a duplicate.
            } catch {
                print("[calendar-write] Google invite failed (\(error.localizedDescription)) — falling back to local event without invites")
            }
        }
        if !ok {
            ok = await createEvent(title: title, start: start, end: end, location: location)
        }
        if !ok {
            // Write failed (e.g. access not yet granted) — release the
            // reservation so a later drain retries.
            var rollback = SharedStore.createdCalendarEventIds
            rollback.remove(eventId)
            SharedStore.createdCalendarEventIds = rollback
        }
        return ok
    }

    /// Drain the backend create_event outbox: write any not-yet-created events
    /// to the calendar, then ack them so the backend drops them. Events already
    /// created by the silent push are acked without re-creating (dedup guard).
    /// This is the reliability net for silent pushes iOS may never deliver.
    @MainActor
    func drainPendingEvents() async {
        let pending: [PendingCalendarEvent]
        do { pending = try await APIClient.shared.getPendingCalendarEvents() }
        catch { return }   // offline / not signed in — retry on next sync
        guard !pending.isEmpty else { return }

        var toAck: [String] = []
        for p in pending {
            guard let start = ISO8601DateFormatter.limor.date(from: p.start_at)
                ?? ISO8601DateFormatter().date(from: p.start_at) else {
                toAck.append(p.event_id)   // unparseable — drop, don't loop forever
                continue
            }
            let end = p.end_at
                .flatMap { ISO8601DateFormatter.limor.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                ?? start.addingTimeInterval(60 * 60)
            let ok = await createTrackedEvent(eventId: p.event_id, title: p.title, start: start, end: end, location: p.location, attendees: p.attendees)
            if ok { toAck.append(p.event_id) }
            // If !ok (e.g. calendar access not yet granted) leave it queued for
            // the next drain.
        }
        if !toAck.isEmpty {
            try? await APIClient.shared.ackPendingCalendarEvents(toAck)
            print("[calendar-drain] handled \(toAck.count)/\(pending.count) pending events")
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
