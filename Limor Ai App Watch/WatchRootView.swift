import SwiftUI

/// Tabbed root for the watchOS app. Three pages, swipe between them:
///   • Next reminder hero — what's due soonest
///   • Shopping list — open items, tap to mark complete
///   • All reminders — pending list
struct WatchRootView: View {
    var body: some View {
        TabView {
            // PTT first — that's the headline feature on the wrist.
            WatchPTTView()
                .tabItem { Text("שאל") }
            WatchNextReminderView()
                .tabItem { Text("עכשיו") }
            WatchShoppingView()
                .tabItem { Text("קניות") }
            WatchRemindersListView()
                .tabItem { Text("תזכורות") }
            WatchMeetingsView()
                .tabItem { Text("פגישות") }
        }
        .tabViewStyle(.verticalPage)
    }
}

#Preview {
    WatchRootView()
        .environment(\.layoutDirection, .rightToLeft)
}
