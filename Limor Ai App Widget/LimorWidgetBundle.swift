import SwiftUI
import WidgetKit

@main
struct LimorWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Home-screen + lock-screen accessory mix: reminder hero + weather
        // at a glance. The original Limor widget, redesigned to match the
        // app's purple gradient identity.
        NowWidget()

        // Standalone reminders list — when the user wants the reminders
        // tab on their home screen instead of in the chat surface.
        RemindersWidget()

        // Standalone shopping list — top items + progress.
        ShoppingWidget()

        // Auto-prioritized "what's next": merges meetings + reminders and
        // shows whichever fires first, with the second in the wings.
        NextUpWidget()

        // Live Activity for the imminent reminder. Untouched — it lives
        // on the Dynamic Island / Lock Screen during the run-up window.
        ReminderLiveActivity()
    }
}
