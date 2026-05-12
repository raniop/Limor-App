import SwiftUI

/// Watch companion to the Limor iPhone app. Read-only mirror of the
/// shopping list + reminders backed by the existing App Group
/// (`group.com.rani.Limor-Ai-App`) — the iPhone app writes to that
/// store via SharedStore, watchOS reads from it on the wrist. Quick
/// actions (tap an item to complete) write back through the same
/// store so the iPhone picks them up via the iCloud KVS change
/// notification or its 5-second poll.
@main
struct LimorWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "he_IL"))
        }
    }
}
