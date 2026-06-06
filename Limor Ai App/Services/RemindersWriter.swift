import EventKit
import Foundation

/// Mirrors backend reminders into iOS Reminders.app. We track which reminder IDs
/// we've already written so each one is created exactly once on this device.
@MainActor
final class RemindersWriter {
    static let shared = RemindersWriter()

    private let store = EKEventStore()
    private(set) var hasAccess = false

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToReminders()
            hasAccess = granted
            return granted
        } catch {
            hasAccess = false
            return false
        }
    }

    /// All reminder lists the user has on this device. Used by the settings
    /// picker so the user can route Limor's reminders into a specific list
    /// (e.g. their personal list, not Family).
    func availableLists() async -> [EKCalendar] {
        if !hasAccess {
            _ = await requestAccess()
        }
        return store.calendars(for: .reminder)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The list new reminders will land in. Honors `SharedStore.remindersListId`
    /// when set; otherwise falls back to the OS default. If the chosen list
    /// has been deleted, transparently falls back too.
    func chosenCalendar() -> EKCalendar? {
        if let id = SharedStore.remindersListId,
           let cal = store.calendar(withIdentifier: id) {
            return cal
        }
        return store.defaultCalendarForNewReminders()
    }

    /// Writes the given reminder to iOS Reminders.app if it hasn't been mirrored yet.
    func writeIfNeeded(reminderId: String, task: String, dueAt: Date) async {
        if SharedStore.syncedReminderIds.contains(reminderId) { return }
        if !hasAccess {
            let granted = await requestAccess()
            if !granted { return }
        }
        guard let calendar = chosenCalendar() else { return }

        let r = EKReminder(eventStore: store)
        r.title = task
        r.calendar = calendar
        r.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: dueAt
        )
        do {
            try store.save(r, commit: true)
            var ids = SharedStore.syncedReminderIds
            ids.insert(reminderId)
            SharedStore.syncedReminderIds = ids
            // Remember the EK identifier so we can flip `isCompleted` or
            // delete it later when the user marks the Limor reminder done.
            var map = SharedStore.syncedReminderEkIds
            map[reminderId] = r.calendarItemIdentifier
            SharedStore.syncedReminderEkIds = map
        } catch {
            print("[reminders-write] failed: \(error.localizedDescription)")
        }
    }

    /// Mirror a list of pending reminders. Idempotent.
    func mirrorAll(_ reminders: [Reminder]) async {
        for r in reminders where r.status == .pending {
            await writeIfNeeded(reminderId: r.id, task: r.task, dueAt: r.dueDate)
        }
    }

    /// Mark the mirrored EKReminder as completed. Best-effort: silently
    /// no-ops if the reminder wasn't mirrored (e.g. created on a different
    /// device, or before this map was introduced), or if the EK item has
    /// since been deleted from the device.
    func markCompleted(reminderId: String) async {
        guard let ekId = SharedStore.syncedReminderEkIds[reminderId] else { return }
        if !hasAccess {
            let granted = await requestAccess()
            if !granted { return }
        }
        guard let item = store.calendarItem(withIdentifier: ekId) as? EKReminder else {
            // EK item gone (user deleted it from Reminders.app). Drop the
            // stale mapping so we don't keep retrying.
            var map = SharedStore.syncedReminderEkIds
            map.removeValue(forKey: reminderId)
            SharedStore.syncedReminderEkIds = map
            return
        }
        if item.isCompleted { return }
        item.isCompleted = true
        do {
            try store.save(item, commit: true)
        } catch {
            print("[reminders-write] markCompleted failed: \(error.localizedDescription)")
        }
    }

    /// Undo a previous `markCompleted` — flip the mirrored EKReminder back
    /// to pending. Same best-effort semantics: no-op if the reminder isn't
    /// mirrored, or if Reminders.app has dropped the item.
    func markPending(reminderId: String) async {
        guard let ekId = SharedStore.syncedReminderEkIds[reminderId] else { return }
        if !hasAccess {
            let granted = await requestAccess()
            if !granted { return }
        }
        guard let item = store.calendarItem(withIdentifier: ekId) as? EKReminder else {
            var map = SharedStore.syncedReminderEkIds
            map.removeValue(forKey: reminderId)
            SharedStore.syncedReminderEkIds = map
            return
        }
        if !item.isCompleted { return }
        item.isCompleted = false
        do {
            try store.save(item, commit: true)
        } catch {
            print("[reminders-write] markPending failed: \(error.localizedDescription)")
        }
    }

    /// Delete the mirrored EKReminder. Called when the user removes the
    /// Limor reminder so the Reminders.app row goes with it instead of
    /// drifting out of sync.
    func delete(reminderId: String) async {
        guard let ekId = SharedStore.syncedReminderEkIds[reminderId] else { return }
        if !hasAccess {
            let granted = await requestAccess()
            if !granted { return }
        }
        defer {
            // Whether or not the save succeeds, drop the mapping —
            // re-trying later won't help.
            var map = SharedStore.syncedReminderEkIds
            map.removeValue(forKey: reminderId)
            SharedStore.syncedReminderEkIds = map
            var ids = SharedStore.syncedReminderIds
            ids.remove(reminderId)
            SharedStore.syncedReminderIds = ids
        }
        guard let item = store.calendarItem(withIdentifier: ekId) as? EKReminder else { return }
        do {
            try store.remove(item, commit: true)
        } catch {
            print("[reminders-write] delete failed: \(error.localizedDescription)")
        }
    }
}
