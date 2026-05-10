import SwiftUI

@main
struct LimorAiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthManager()
    @StateObject private var push = PushManager.shared
    @StateObject private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(push)
                .environmentObject(router)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
