import GoogleSignIn
import MSAL
import SwiftUI
import UserNotifications

@main
struct LimorAiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthManager()
    @StateObject private var push = PushManager.shared
    @StateObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Wire up the Watch-Connectivity bridge as early as possible so
        // the first SharedStore writes after app launch can already
        // ride a delivered context to the watch instead of waiting for
        // the next mutation.
        WatchSyncManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(push)
                .environmentObject(router)
                .environment(\.layoutDirection, .rightToLeft)
                .onChange(of: scenePhase) { _, newPhase in
                    // Keep on-device notification schedules fresh — re-run
                    // whenever the app comes to the foreground so iOS
                    // doesn't end up with stale pending requests if
                    // anything (event change, reminder edit, OS purge)
                    // happened while we were backgrounded.
                    if newPhase == .active {
                        Task {
                            await MeetingsNotifier.reschedule()
                            await RecurringRemindersScheduler.reschedule()
                        }
                        // Belt-and-suspenders for backend push: re-fetch the
                        // current FCM token from Firebase Messaging and re-
                        // upload to the backend. The delegate callback only
                        // fires when the token *changes*, so if the original
                        // upload after install/sign-in failed (network race,
                        // auth not ready), we'd otherwise stay un-registered
                        // forever and no reminder/daily push would arrive.
                        Task { await PushManager.shared.refreshAndUploadToken() }
                        // Re-render any Live Activity so the "overdue" tint
                        // and label flip the moment the user opens the app —
                        // ActivityKit widgets don't auto-rerun their body
                        // when time passes; only the embedded Text(.timer)
                        // ticks on its own.
                        Task {
                            await ActivityController.endIfOverdue()
                            await ActivityController.refresh()
                        }
                        // Pull any iCloud changes other devices wrote
                        // while we were backgrounded — the KVS external-
                        // change notification doesn't always fire on its
                        // own when the app first foregrounds.
                        SharedStore.mirrorMeetingsNotifFromICloud()
                        ShoppingListStore.shared.refreshFromICloud()
                        RecurringRemindersStore.shared.refreshFromICloud()
                        // Re-push the latest snapshot to the watch — covers
                        // simulator pairs where App Group + iCloud don't
                        // bridge between the iPhone and Watch processes.
                        WatchSyncManager.shared.pushSnapshot()
                        // Clear the app-icon red dot now that the user is
                        // looking at the app. The backend sends `aps.badge=1`
                        // on every visible push so the icon picks up a dot
                        // for any waiting notification; resetting on .active
                        // means the dot disappears the moment the user
                        // actually opens us, which is what they asked for.
                        Task {
                            try? await UNUserNotificationCenter.current()
                                .setBadgeCount(0)
                        }
                    }
                }
                .onOpenURL { url in
                    // SwiftUI delivers scene-routed URLs here. The
                    // UIApplicationDelegate `open url` callback isn't always
                    // fired in scene-based apps, so the Microsoft
                    // Authenticator broker handoff (which returns via
                    // `msauth.<bundle>://`) was getting dropped. Route the
                    // URL to both auth SDKs — whichever owns it consumes it,
                    // the other no-ops.
                    print("[url] onOpenURL fired: \(url)")
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    let handled = MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
                    print("[url] MSAL handled response: \(handled)")
                }
        }
    }
}
