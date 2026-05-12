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
                    // Keep the on-device "tomorrow's meetings" notification
                    // fresh — re-schedule whenever the app comes to the
                    // foreground so newly-added events make it into the
                    // next push without the user having to do anything.
                    if newPhase == .active {
                        Task { await MeetingsNotifier.reschedule() }
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
