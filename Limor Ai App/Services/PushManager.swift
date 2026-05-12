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

    /// Attach a "Mark Done" / "Snooze 10 min" pair to reminder pushes.
    /// Categories are matched at *delivery* time, so this registration
    /// must run before any reminder notification arrives — calling from
    /// `didFinishLaunchingWithOptions` covers cold launches.
    private func registerNotificationCategories() {
        let complete = UNNotificationAction(
            identifier: Self.reminderCompleteActionId,
            title: "סמן כטופל",
            options: [.authenticationRequired]
        )
        let snooze = UNNotificationAction(
            identifier: Self.reminderSnoozeActionId,
            title: "נודניק 10 דק'",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.reminderCategoryId,
            actions: [complete, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
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
        default:
            break
        }
        completionHandler()
    }
}
