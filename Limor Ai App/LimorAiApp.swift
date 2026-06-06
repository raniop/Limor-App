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
        // Re-attach push-token / lifecycle subscribers to any Live
        // Activities that survived the previous launch. iOS persists
        // activities across relaunches; the AsyncSequence subscriptions
        // do not, so without this a token rotation after relaunch would
        // never reach the backend and the activity push at due time
        // would silently miss.
        Task { @MainActor in
            ActivityController.reattachExistingActivities()
        }
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
                            await LeadTimeNotifier.reschedule()
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
                        // Drain any pending iOS-Share-Sheet handoffs left
                        // in the App Group. The trampoline URL
                        // (`limor://share`) is best-effort — the responder-
                        // chain trick that fires it from the extension can
                        // silently no-op on iOS 18, so we *also* check a
                        // dedicated "shouldOpenChat" App-Group flag the
                        // extension sets when the user taps "פתח בצ׳אט".
                        // Whichever signal arrives first wins; the other is
                        // a no-op.
                        //
                        // The flag check happens *synchronously* in this
                        // MainActor onChange closure (no Task wrapper).
                        // Wrapping in `Task { @MainActor in }` introduced a
                        // race on cold launch: by the time the task fired,
                        // SplashView was still on screen and MainTabs's
                        // TabView hadn't materialized yet, so the
                        // `selectedTab = .chat` assignment landed before
                        // there were any observers — TabView then started
                        // at its default `.now` and never got the change.
                        if ShareInbox.shouldOpenChat {
                            AppRouter.shared.selectedTab = .chat
                            ShareInbox.shouldOpenChat = false
                            print("[share] consumed App-Group shouldOpenChat flag → chat tab")
                            // Re-apply once the splash has dropped — by
                            // ~700ms the splash min-duration is over and
                            // MainTabs is in the view tree. Cheap insurance
                            // against the launch-race window.
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(700))
                                if AppRouter.shared.selectedTab != .chat {
                                    AppRouter.shared.selectedTab = .chat
                                    print("[share] re-applied selectedTab=.chat after splash")
                                }
                            }
                        }
                        Task { @MainActor in
                            drainShareInboxToChat()
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
                    if url.scheme == "limor" {
                        // The "open in chat" CTA in the Share Extension is
                        // the only thing that fires this scheme today, so
                        // always land the user in the chat tab — *also*
                        // when the inbox is empty (which it usually is now
                        // that the extension sends to the backend inline
                        // and the queue is the failure-fallback path).
                        AppRouter.shared.selectedTab = .chat
                        // Clear the App-Group fallback flag so the
                        // scenePhase hook doesn't double-fire the same
                        // tab switch a moment later.
                        ShareInbox.shouldOpenChat = false
                        drainShareInboxToChat()
                        return
                    }
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    let handled = MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: nil)
                    print("[url] MSAL handled response: \(handled)")
                }
        }
    }

    /// Move whatever the Share Extension queued in the App Group into the
    /// chat tab. Iterates oldest-first; the last item wins for the slot
    /// (pendingChatMessage is single-valued), so earlier shares are still
    /// dispatched via `sendToLimor` in sequence — `consumePendingMessageIfAny`
    /// fires on every `pendingChatMessage` change.
    @MainActor
    private func drainShareInboxToChat() {
        let items = ShareInbox.drainAll()
        print("[share] drainShareInboxToChat: \(items.count) pending item(s)")
        guard !items.isEmpty else { return }
        for item in items {
            let imageData = ShareInbox.consumeImageData(for: item)
            let text = item.text ?? ""
            print("[share]  → item \(item.id.uuidString.prefix(8)) text=\(text.prefix(40).debugDescription) imageBytes=\(imageData?.count ?? 0)")
            if let imageData {
                AppRouter.shared.sendToLimor(
                    text: text,
                    attachment: .init(
                        data: imageData,
                        mime: "image/jpeg",
                        filename: "shared-\(item.id.uuidString.prefix(8)).jpg"
                    )
                )
            } else if !text.isEmpty {
                AppRouter.shared.sendToLimor(text)
            }
        }
    }
}
