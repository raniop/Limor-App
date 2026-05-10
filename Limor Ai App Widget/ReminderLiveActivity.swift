import ActivityKit
import SwiftUI
import WidgetKit

struct ReminderLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LimorReminderAttributes.self) { context in
            // Lock-screen / notification banner.
            LockScreenView(attributes: context.attributes, state: context.state)
                .padding()
                .activityBackgroundTint(
                    isOverdue(context.state.dueAt)
                        ? Color.red.opacity(0.9)
                        : Color.indigo.opacity(0.85)
                )
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.dueAt, style: .timer)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: 80)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.task)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("לימור — תזכורת").font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "bell.fill").foregroundStyle(.tint)
            } compactTrailing: {
                Text(context.state.dueAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 60)
            } minimal: {
                Image(systemName: "bell.fill").foregroundStyle(.tint)
            }
            .keylineTint(.indigo)
        }
    }
}

private struct LockScreenView: View {
    let attributes: LimorReminderAttributes
    let state: LimorReminderAttributes.ContentState

    private var overdue: Bool { isOverdue(state.dueAt) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: overdue ? "exclamationmark.triangle.fill" : "bell.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.95))
            VStack(alignment: .leading, spacing: 2) {
                Text(overdue ? "תזכורת באיחור" : "תזכורת")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Text(attributes.task).font(.headline).foregroundStyle(.white)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(state.dueAt, style: .timer)
                    .monospacedDigit()
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
                Text(overdue ? "עבר הזמן" : "עד הזמן")
                    .font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

func isOverdue(_ dueAt: Date) -> Bool {
    dueAt.timeIntervalSinceNow < 0
}
