import SwiftUI

/// Tabbed root for the watchOS app. Three pages, swipe between them:
///   • Next reminder hero — what's due soonest
///   • Shopping list — open items, tap to mark complete
///   • All reminders — pending list
struct WatchRootView: View {
    var body: some View {
        TabView {
            WatchNextReminderView()
                .tabItem { Text("עכשיו") }
            WatchShoppingView()
                .tabItem { Text("קניות") }
            WatchRemindersListView()
                .tabItem { Text("תזכורות") }
        }
        .tabViewStyle(.verticalPage)
    }
}

#Preview {
    WatchRootView()
        .environment(\.layoutDirection, .rightToLeft)
}
