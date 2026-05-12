import GoogleSignIn
import MSAL
import SwiftUI

@main
struct LimorAiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthManager()
    @StateObject private var push = PushManager.shared
    @StateObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

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
                        // Pull any iCloud changes other devices wrote
                        // while we were backgrounded — the KVS external-
                        // change notification doesn't always fire on its
                        // own when the app first foregrounds.
                        SharedStore.mirrorMeetingsNotifFromICloud()
                        ShoppingListStore.shared.refreshFromICloud()
                        RecurringRemindersStore.shared.refreshFromICloud()
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
