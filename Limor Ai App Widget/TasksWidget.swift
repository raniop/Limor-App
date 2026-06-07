import SwiftUI
import WidgetKit

// MARK: - Entry

struct TasksEntry: TimelineEntry {
    let date: Date
    let tasks: [LimorTask]

    var open: [LimorTask] { tasks.filter { !$0.done } }

    static let placeholder = TasksEntry(
        date: Date(),
        tasks: [
            LimorTask(id: "1", title: "לקנות ספרי קריאה ליהלי", done: false, tags: ["בית"], created_at: "", completed_at: nil),
            LimorTask(id: "2", title: "להזמין תור למוסך", done: false, tags: ["רכב"], created_at: "", completed_at: nil),
            LimorTask(id: "3", title: "לשלוח חוזה ללקוח", done: false, tags: ["עבודה"], created_at: "", completed_at: nil),
            LimorTask(id: "4", title: "לסדר את המחסן", done: true, tags: [], created_at: "", completed_at: nil),
        ]
    )
}

// MARK: - Provider

struct TasksProvider: TimelineProvider {
    func placeholder(in context: Context) -> TasksEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TasksEntry) -> Void) {
        if context.isPreview { completion(.placeholder); return }
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TasksEntry>) -> Void) {
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [load()], policy: .after(nextRefresh)))
    }

    private func load() -> TasksEntry {
        TasksEntry(date: Date(), tasks: SharedStore.loadTasks())
    }
}

// MARK: - Widget

struct TasksWidget: Widget {
    let kind: String = "TasksWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TasksProvider()) { entry in
            TasksWidgetView(entry: entry)
                .limorWidgetContainer()
        }
        .configurationDisplayName("המשימות שלי")
        .description("המשימות הפתוחות שלך, במבט אחד.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Root view

struct TasksWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: TasksEntry

    private var open: [LimorTask] { entry.open }

    var body: some View {
        switch family {
        case .systemSmall:  small
        case .systemLarge:  large
        default:            medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetSectionLabel(icon: "checklist", text: "משימות")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(open.count)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetBrand.heroGradient)
                    .monospacedDigit()
                Text(open.count == 1 ? "פתוחה" : "פתוחות")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetBrand.muted)
            }
            Spacer(minLength: 0)
            if open.isEmpty {
                Text("הכול סגור ✨")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WidgetBrand.muted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(open.prefix(2)) { t in
                        Text("• \(t.title)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WidgetBrand.ink)
                            .lineLimit(1)
                    }
                    if open.count > 2 {
                        Text("+\(open.count - 2) נוספות")
                            .font(.caption2)
                            .foregroundStyle(WidgetBrand.muted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetSectionLabel(icon: "checklist", text: "המשימות שלי")
                Spacer()
                Text("\(open.count) פתוחות")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetBrand.indigo)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(WidgetBrand.indigo.opacity(0.15)))
            }
            if open.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(open.prefix(4)) { t in row(t) }
                    if open.count > 4 {
                        Text("+\(open.count - 4) נוספות")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WidgetBrand.indigo)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetSectionLabel(icon: "checklist", text: "המשימות שלי")
            if open.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 36))
                            .foregroundStyle(WidgetBrand.indigo.opacity(0.6))
                        Text("אין משימות פתוחות")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WidgetBrand.ink)
                        Text("בקש מלימור להוסיף משימה.")
                            .font(.caption)
                            .foregroundStyle(WidgetBrand.muted)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                VStack(spacing: 5) {
                    ForEach(open.prefix(9)) { t in row(t) }
                    if open.count > 9 {
                        Text("+\(open.count - 9) נוספות")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WidgetBrand.indigo)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ t: LimorTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.body.weight(.bold))
                .foregroundStyle(WidgetBrand.indigo)
            Text(t.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WidgetBrand.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let tag = t.tags.first {
                Text(tag)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetBrand.violet)
                    .lineLimit(1)
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(WidgetBrand.indigo.opacity(0.6))
                .font(.title3)
            Text("אין משימות — בקש מלימור להוסיף")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WidgetBrand.ink)
            Spacer()
        }
    }
}
