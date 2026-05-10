import SwiftUI
import WidgetKit

@main
struct LimorWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowWidget()
        ReminderLiveActivity()
    }
}
