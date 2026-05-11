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
        return true
    }

    /// Google Sign-In and MSAL both complete by opening a custom URL back into
    /// the app — this hook hands it off to whichever library claims it.
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        if GIDSignIn.sharedInstance.handle(url) {
            return true
        }
        let sourceApp = options[.sourceApplication] as? String
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
        completionHandler()
    }
}
