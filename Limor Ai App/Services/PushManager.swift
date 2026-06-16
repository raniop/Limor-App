import FirebaseCore
import FirebaseMessaging
import Foundation
import GoogleSignIn
import MSAL
import UIKit
import UserNotifications

@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    @Published private(set) var permissionGranted = false
    @Published private(set) var fcmToken: String?

    private override init() {
        super.init()
    }

    func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        print("[push] notification authorization status: \(settings.authorizationStatus.rawValue)")

        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                permissionGranted = granted
                print("[push] permission requested → granted=\(granted)")
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                    print("[push] called registerForRemoteNotifications()")
                }
            } catch {
                permissionGranted = false
                print("[push] permission request error: \(error.localizedDescription)")
            }
        case .authorized, .provisional, .ephemeral:
            permissionGranted = true
            UIApplication.shared.registerForRemoteNotifications()
            print("[push] already authorized, called registerForRemoteNotifications()")
        case .denied:
            permissionGranted = false
            print("[push] notifications DENIED — user has to enable in Settings → Limor → Notifications")
        @unknown default:
            permissionGranted = false
        }
    }

    func handleFcmToken(_ token: String) {
        print("[push] received FCM token: \(token.prefix(20))…")
        fcmToken = token
        Task { await uploadIfPossible() }
    }

    func uploadIfPossible() async {
        guard let token = fcmToken, !token.isEmpty else {
            print("[push] uploadIfPossible: no FCM token yet")
            return
        }
        do {
            try await APIClient.shared.registerFcmToken(token: token, deviceName: UIDevice.current.name)
            print("[push] FCM token uploaded to backend ✅")
        } catch {
            print("[push] register FCM token failed: \(error.localizedDescription)")
        }
    }

    /// Actively pull the current FCM registration token from Firebase Messaging
    /// and re-upload it to the backend. The `MessagingDelegate` callback only
    /// fires when Firebase decides to refresh the token — across re-installs
    /// and transient network/auth races at launch, it's possible to end up
    /// with the backend missing our token and the delegate never firing again.
    /// This is the belt-and-suspenders path: call on every foreground.
    func refreshAndUploadToken() async {
        let token: String? = await withCheckedContinuation { cont in
            Messaging.messaging().token { token, error in
                if let error {
                    print("[push] Messaging.token error: \(error.localizedDescription)")
                }
                cont.resume(returning: token)
            }
        }
        guard let token, !token.isEmpty else {
            print("[push] refreshAndUploadToken: no token from Firebase Messaging")
            return
        }
        if fcmToken != token {
            print("[push] refreshAndUploadToken: token changed since last cache")
        }
        fcmToken = token
        await uploadIfPossible()
    }

    func unregisterCurrentToken() async throws {
        guard let token = fcmToken else { return }
        try await APIClient.shared.unregisterFcmToken(token: token)
    }
}

// MARK: - AppDelegate (Firebase + UNUserNotificationCenter + Google Sign-In URL handling)

final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        return true
    }

    /// Identifiers shared between the iOS-side category registration and
    /// the backend APNs payload. Backend tags reminder pushes with
    /// `category: "LIMOR_REMINDER"` so the two action buttons attached
    /// here ("סמן כטופל" / "נודניק 10 דקות") surface on the banner +
    /// lock-screen long-press.
    static let reminderCategoryId = "LIMOR_REMINDER"
    static let reminderCompleteActionId = "LIMOR_REMINDER_COMPLETE"
    static let reminderSnoozeActionId = "LIMOR_REMINDER_SNOOZE_10"

    /// Categories + action for the local "2 hours before" heads-up
    /// (`LeadTimeNotifier`). The meeting variant carries only the
    /// "remind me in an hour" snooze; the reminder variant adds
    /// "mark done" on top so the user can still close it out early.
    /// `LIMOR_LEAD_SNOOZE_1H` schedules a fresh notification 1h later —
    /// i.e. one hour before the event — handled in `didReceive`.
    static let leadMeetingCategoryId = "LIMOR_LEAD_MEETING"
    static let leadReminderCategoryId = "LIMOR_LEAD_REMINDER"
    static let leadSnooze1hActionId = "LIMOR_LEAD_SNOOZE_1H"

    /// Attach a "Mark Done" / "Snooze 10 min" pair to reminder pushes.
    /// Categories are matched at *delivery* time, so this registration
    /// must run before any reminder notification arrives — calling from
    /// `didFinishLaunchingWithOptions` covers cold launches.
    private func registerNotificationCategories() {
        let complete = UNNotificationAction(
            identifier: Self.reminderCompleteActionId,
            title: tr("סמן כטופל", "Mark Done"),
            options: [.authenticationRequired]
        )
        let snooze = UNNotificationAction(
            identifier: Self.reminderSnoozeActionId,
            title: tr("נודניק 10 דק'", "Snooze 10 min"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.reminderCategoryId,
            actions: [complete, snooze],
            intentIdentifiers: [],
            options: []
        )

        // "2 hours before" heads-up: one-tap re-nudge an hour later.
        let snooze1h = UNNotificationAction(
            identifier: Self.leadSnooze1hActionId,
            title: tr("תזכיר לי עוד שעה", "Remind me in an hour"),
            options: []
        )
        let leadMeeting = UNNotificationCategory(
            identifier: Self.leadMeetingCategoryId,
            actions: [snooze1h],
            intentIdentifiers: [],
            options: []
        )
        let leadReminder = UNNotificationCategory(
            identifier: Self.leadReminderCategoryId,
            actions: [snooze1h, complete],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category, leadMeeting, leadReminder])
    }

    /// Google Sign-In and MSAL both complete by opening a custom URL back into
    /// the app — this hook hands it off to whichever library claims it.
    /// `LimorAiApp.body` also calls `MSALPublicClientApplication.handleMSALResponse`
    /// from `.onOpenURL`; whichever fires first owns the URL and the other no-ops.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        let sourceApp = options[.sourceApplication] as? String
        print("[url] AppDelegate open url: \(url) source=\(sourceApp ?? "nil")")
        if GIDSignIn.sharedInstance.handle(url) {
            return true
        }
        return MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: sourceApp)
    }

    // MARK: APNs registration callbacks
    //
    // Firebase Messaging swizzles these too, but logging from here gives us
    // visibility when something goes wrong (e.g. App ID without Push capability).

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[push] APNs device token received (\(deviceToken.count) bytes): \(hex.prefix(20))…")
        // Belt-and-suspenders alongside Firebase swizzling.
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[push] APNs registration FAILED: \(error.localizedDescription)")
        let ns = error as NSError
        print("[push]   domain=\(ns.domain) code=\(ns.code)")
    }

    /// Silent (background) push handler — fires for `aps.content-available=1`
    /// pushes from the backend. The `data.kind` field tells us which local
    /// store to refresh. Used for cross-device live sync (e.g. shopping
    /// list edits on another device).
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let kind = (userInfo["kind"] as? String) ?? ""
        let keys = userInfo.keys.compactMap { $0 as? String }
        print("[push] silent push received kind=\(kind) keys=\(keys)")
        guard !kind.isEmpty else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            switch kind {
            case "shopping":
                print("[push] refreshing shopping from backend")
                await ShoppingListStore.shared.refreshFromBackend()
                completionHandler(.newData)
            case "shopping_shared":
                // The other member edited the SHARED list — re-pull it.
                print("[push] refreshing shared shopping list")
                await SharedShoppingStore.shared.load()
                completionHandler(.newData)
            case "shopping_add":
                // Limor's `add_shopping_item` tool can't write to the
                // user's iCloud directly, so the backend sends this
                // silent push and we do the actual add on-device.
                // `ShoppingListStore.add` handles dedup and pushes the
                // new state back to iCloud + backend.
                if let item = userInfo["item"] as? String, !item.isEmpty {
                    let added = ShoppingListStore.shared.add(item)
                    print("[push] shopping_add('\(item)') → added=\(added)")
                } else {
                    print("[push] shopping_add: missing 'item'")
                }
                completionHandler(.newData)
            case "shopping_complete":
                if let item = userInfo["item"] as? String, !item.isEmpty {
                    let done = ShoppingListStore.shared.completeByName(item)
                    print("[push] shopping_complete('\(item)') → matched=\(done)")
                } else {
                    print("[push] shopping_complete: missing 'item'")
                }
                completionHandler(.newData)
            case "create_event":
                // Limor's `create_event` tool can't write to the device
                // calendar from the backend, so it sends this silent push and
                // we create the EKEvent on-device (mirrors `shopping_add`).
                let title = (userInfo["title"] as? String) ?? ""
                let startStr = userInfo["start_at"] as? String
                // event_id ties this push to the Firestore outbox entry so the
                // foreground drain won't create the same event a second time.
                let eventId = (userInfo["event_id"] as? String) ?? ""
                if !title.isEmpty, !eventId.isEmpty, let startStr,
                   let start = ISO8601DateFormatter.limor.date(from: startStr) ?? ISO8601DateFormatter().date(from: startStr) {
                    let end = (userInfo["end_at"] as? String)
                        .flatMap { ISO8601DateFormatter.limor.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                        ?? start.addingTimeInterval(60 * 60)
                    let location = userInfo["location"] as? String
                    let ok = await CalendarManager.shared.createTrackedEvent(eventId: eventId, title: title, start: start, end: end, location: location)
                    // Created on this device — clear it from the outbox so the
                    // drain doesn't revisit it.
                    if ok { try? await APIClient.shared.ackPendingCalendarEvents([eventId]) }
                    print("[push] create_event('\(title)') → \(ok)")
                } else {
                    print("[push] create_event: missing/invalid title/start_at/event_id")
                }
                completionHandler(.newData)
            case "reminder":
                // Backend stamps `kind: "reminder"` + `wakeApp: true` on
                // each reminder push, so this path also fires while the
                // user is on the lock screen — the iOS-native banner is
                // shown by the system, and the ~30s background window
                // this hands us is enough to re-render the matching
                // Live Activity (flips "עד הזמן" → "עבר הזמן" and the
                // tint from indigo to red without waiting for the user
                // to open the app). `endIfOverdue` then sweeps any
                // activity that's drifted far past due so the lock
                // screen doesn't keep an ancient one pinned.
                print("[push] reminder push received — refreshing Live Activity")
                await ActivityController.endIfOverdue()
                await ActivityController.refresh()
                completionHandler(.newData)
            case "briefing_ready", "briefing_failed":
                // The background CEO-briefing generation finished. Broadcast so
                // an open BriefingView re-fetches; iOS shows the visible banner
                // itself, so the user is notified even when backgrounded.
                print("[push] briefing \(kind)")
                NotificationCenter.default.post(name: .limorBriefingReady, object: nil)
                completionHandler(.newData)
            default:
                print("[push] unknown kind, ignoring")
                completionHandler(.noData)
            }
        }
    }

    // MARK: MessagingDelegate

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken else { return }
        Task { @MainActor in
            PushManager.shared.handleFcmToken(token)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
        // Foreground delivery path. `didReceiveRemoteNotification` handles
        // the lock-screen / background case; this covers "app is open
        // when the reminder fires", which `content-available` won't fire
        // for. Same effect: flip the Live Activity to its overdue look.
        let userInfo = notification.request.content.userInfo
        if (userInfo["kind"] as? String) == "reminder" {
            Task { @MainActor in
                await ActivityController.endIfOverdue()
                await ActivityController.refresh()
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let reminderId = userInfo["reminder_id"] as? String

        switch actionId {
        case AppDelegate.reminderCompleteActionId:
            if let reminderId {
                Task { @MainActor in
                    do {
                        _ = try await APIClient.shared.completeReminder(token: "", id: reminderId)
                        print("[push] reminder \(reminderId) marked done from notification")
                        // Mirror the completion into iOS Reminders.app too,
                        // so a row the user mirrored over there gets checked
                        // off whether they tapped "Done" inside the app or
                        // straight from the lock-screen notification.
                        await RemindersWriter.shared.markCompleted(reminderId: reminderId)
                    } catch {
                        print("[push] complete-from-notification failed: \(error.localizedDescription)")
                    }
                    completionHandler()
                }
                return
            }
        case AppDelegate.reminderSnoozeActionId:
            if let reminderId {
                Task { @MainActor in
                    do {
                        _ = try await APIClient.shared.snoozeReminder(token: "", id: reminderId, minutes: 10)
                        print("[push] reminder \(reminderId) snoozed 10 min from notification")
                    } catch {
                        print("[push] snooze-from-notification failed: \(error.localizedDescription)")
                    }
                    completionHandler()
                }
                return
            }
        case AppDelegate.leadSnooze1hActionId:
            // "תזכיר לי עוד שעה" on a 2h-before heads-up → fire a fresh
            // local notification one hour from now (i.e. ~1h before the
            // event). No backend hop; this is a pure on-device reschedule.
            scheduleOneHourSnooze(from: userInfo, reminderId: reminderId)
            completionHandler()
            return
        default:
            break
        }
        completionHandler()
    }

    /// Re-arm a lead-time heads-up an hour later. Reuses the title carried
    /// in `userInfo` from the original "2 hours before" notification. For a
    /// reminder we re-attach the reminder category + id so the follow-up
    /// still offers "mark done"; meetings get a plain banner.
    nonisolated private func scheduleOneHourSnooze(from userInfo: [AnyHashable: Any], reminderId: String?) {
        let title = (userInfo["lead_title"] as? String) ?? tr("תזכורת", "Reminder")
        let isReminder = (userInfo["lead_kind"] as? String) == "reminder"

        let content = UNMutableNotificationContent()
        content.title = tr("בעוד שעה: \(title)", "In an hour: \(title)")
        content.sound = .default
        if isReminder, let reminderId {
            content.categoryIdentifier = AppDelegate.reminderCategoryId
            content.userInfo = ["reminder_id": reminderId]
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60 * 60, repeats: false)
        // Stable id keyed to the source so a double-tap can't queue two.
        let key = reminderId ?? title
        let request = UNNotificationRequest(
            identifier: "limor.lead.snoozed.\(key)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[push] 1h-snooze schedule failed: \(error.localizedDescription)")
            } else {
                print("[push] 1h-snooze scheduled for '\(title)'")
            }
        }
    }
}
