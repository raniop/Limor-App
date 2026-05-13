import ActivityKit
import Foundation

/// Manages the Live Activity for the next reminder. Best-effort: silently
/// no-ops if Live Activities are disabled by the user.
///
/// Push update flow (Activity push tokens):
///
/// When an activity is started with `pushType: .token`, iOS hands us an
/// APNs-style device token via `activity.pushTokenUpdates`. We send that
/// token to the backend tagged with the reminder id, and at due time the
/// backend hits APNs directly with an `apns-push-type: liveactivity` push
/// — that's the one Apple-blessed way to flip the activity to its overdue
/// look while the app is backgrounded or even force-quit. Hybrid FCM
/// pushes (alert + content-available) don't cut it: iOS doesn't reliably
/// wake the app for visible pushes, even with the entitlement.
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
            let activity = try Activity.request(
                attributes: attrs,
                content: content,
                // .token tells ActivityKit to mint an APNs push token we
                // can register with the backend. The alternative `nil`
                // means "no remote updates" and is what we had before —
                // worked while the app was foregrounded but left the
                // lock-screen widget frozen on its initial state.
                pushType: .token
            )
            watchPushToken(of: activity, reminderId: reminder.id)
            watchLifecycle(of: activity, reminderId: reminder.id)
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
                try? await APIClient.shared.deregisterLiveActivityToken(
                    reminderId: activity.attributes.reminderId
                )
            }
        }
    }

    /// Re-push the existing content to every live activity so the widget
    /// re-renders. ActivityKit widgets only re-evaluate their body closure
    /// when `update(_:)` is called — `style: .timer` keeps the countdown
    /// ticking on its own, but the conditional UI that depends on "is it
    /// past dueAt yet?" (background tint, "תזכורת באיחור" label, the
    /// exclamation icon) stays frozen at the value it had when the activity
    /// last received an update. Calling this on every foreground covers
    /// the case where the user unlocks their phone after the due time has
    /// passed while the app was backgrounded.
    @MainActor
    static func refresh() async {
        for activity in Activity<LimorReminderAttributes>.activities {
            let state = activity.content.state
            let stale = state.dueAt.addingTimeInterval(60 * 60)
            let content = ActivityContent<LimorReminderAttributes.ContentState>(
                state: state, staleDate: stale
            )
            await activity.update(content)
        }
    }

    @MainActor
    static func endAll() async {
        for activity in Activity<LimorReminderAttributes>.activities {
            try? await APIClient.shared.deregisterLiveActivityToken(
                reminderId: activity.attributes.reminderId
            )
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Re-attach the push-token / lifecycle subscriptions to every
    /// in-flight activity on app launch. Without this the AsyncSequence
    /// subscriptions die with the previous process and a token rotation
    /// that happens after relaunch never reaches the backend, breaking
    /// liveactivity push delivery silently. Call once from app startup.
    @MainActor
    static func reattachExistingActivities() {
        for activity in Activity<LimorReminderAttributes>.activities {
            watchPushToken(of: activity, reminderId: activity.attributes.reminderId)
            watchLifecycle(of: activity, reminderId: activity.attributes.reminderId)
        }
    }

    /// Subscribe to push-token updates for one activity. iOS emits the
    /// initial token shortly after `Activity.request` returns, and may
    /// rotate it periodically — both deliveries push to the backend so
    /// the latest token is the one APNs hits at due time.
    private static func watchPushToken<A: ActivityAttributes>(
        of activity: Activity<A>,
        reminderId: String
    ) {
        Task.detached {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                print("[live-activity] push token for \(reminderId): \(hex.prefix(16))…")
                do {
                    try await APIClient.shared.registerLiveActivityToken(
                        reminderId: reminderId, pushToken: hex
                    )
                } catch {
                    print("[live-activity] register token failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Subscribe to activity state changes so we can drop the backend's
    /// stored push token the moment iOS ends or dismisses an activity.
    /// Without this we'd accumulate dead tokens and the backend would
    /// keep trying to push to APNs endpoints that always return 410.
    private static func watchLifecycle<A: ActivityAttributes>(
        of activity: Activity<A>,
        reminderId: String
    ) {
        Task.detached {
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed || state == .stale {
                    print("[live-activity] state=\(state) for \(reminderId) → deregistering")
                    try? await APIClient.shared.deregisterLiveActivityToken(
                        reminderId: reminderId
                    )
                }
            }
        }
    }
}
