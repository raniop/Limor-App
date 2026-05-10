import ActivityKit
import Foundation

/// Manages the Live Activity for the next reminder. Best-effort: silently
/// no-ops if Live Activities are disabled by the user.
enum ActivityController {
    /// If `next` is within the next 4 hours, ensure a Live Activity exists for it.
    /// If a different reminder is currently active, end it first. If `next` is nil
    /// or far in the future, end any existing activities.
    @MainActor
    static func sync(with next: Reminder?) async {
        let auth = ActivityAuthorizationInfo()
        guard auth.areActivitiesEnabled else { return }

        // Drop activities for completed or distant reminders.
        guard
            let reminder = next,
            reminder.status == .pending,
            reminder.dueDate.timeIntervalSinceNow < 4 * 60 * 60,
            reminder.dueDate.timeIntervalSinceNow > -3600  // ≤ 1h overdue
        else {
            await endAll()
            return
        }

        let newState = LimorReminderAttributes.ContentState(dueAt: reminder.dueDate)
        // Stale = "after this point the activity is informational only".
        // The system also tears it down ~4 hours after the staleDate.
        let stale = reminder.dueDate.addingTimeInterval(60 * 60)
        let content = ActivityContent<LimorReminderAttributes.ContentState>(state: newState, staleDate: stale)

        if let existing = Activity<LimorReminderAttributes>.activities.first(where: {
            $0.attributes.reminderId == reminder.id
        }) {
            await existing.update(content)
            return
        }

        // End any stale activities for other reminders.
        await endAll()

        let attrs = LimorReminderAttributes(reminderId: reminder.id, task: reminder.task)
        do {
            _ = try Activity.request(attributes: attrs, content: content, pushType: nil)
        } catch {
            print("[live-activity] start failed: \(error.localizedDescription)")
        }
    }

    /// End any activity whose due time is more than `gracePeriodMinutes` past.
    /// Run periodically so the lock-screen doesn't show a stale activity.
    @MainActor
    static func endIfOverdue(gracePeriodMinutes: Double = 60) async {
        let cutoff = Date().addingTimeInterval(-gracePeriodMinutes * 60)
        for activity in Activity<LimorReminderAttributes>.activities {
            if activity.content.state.dueAt < cutoff {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @MainActor
    static func endAll() async {
        for activity in Activity<LimorReminderAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
