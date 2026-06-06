import SwiftUI
import WidgetKit

// MARK: - Entry

struct RemindersEntry: TimelineEntry {
    let date: Date
    let reminders: [Reminder]
    let isPlaceholder: Bool

    static let placeholder = RemindersEntry(
        date: Date(),
        reminders: [
            Self.fakeReminder(task: "להתקשר לאמא",     dueIn: 30 * 60),
            Self.fakeReminder(task: "להוציא כביסה",    dueIn: 2 * 3600),
            Self.fakeReminder(task: "פגישה עם דני",    dueIn: 5 * 3600),
            Self.fakeReminder(task: "להזמין מתנה",      dueIn: 23 * 3600),
        ],
        isPlaceholder: true
    )

    private static func fakeReminder(task: String, dueIn seconds: TimeInterval) -> Reminder {
        Reminder(
            id: UUID().uuidString,
            task: task,
            due_at: ISO8601DateFormatter.limor.string(from: Date().addingTimeInterval(seconds)),
            status: .pending,
            created_at: ISO8601DateFormatter.limor.string(from: Date()),
            completed_at: nil,
            msUntilDue: seconds * 1000,
            isOverdue: false
        )
    }
}

// MARK: - Provider

struct RemindersProvider: TimelineProvider {
    func placeholder(in context: Context) -> RemindersEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (RemindersEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder); return
        }
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RemindersEntry>) -> Void) {
        let entry = load()
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    /// Reads the cached reminders that the main app keeps fresh in the App
    /// Group. No network — the widget is a read-only mirror of whatever
    /// the user saw last time they opened the app.
    private func load() -> RemindersEntry {
        let all = SharedStore.loadReminders()
        let pending = all
            .filter { $0.status == .pending }
            .sorted { $0.dueDate < $1.dueDate }
        return RemindersEntry(date: Date(), reminders: pending, isPlaceholder: false)
    }
}

// MARK: - Widget

struct RemindersWidget: Widget {
    let kind: String = "RemindersWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RemindersProvider()) { entry in
            RemindersWidgetView(entry: entry)
                .limorWidgetContainer()
        }
        .configurationDisplayName("תזכורות")
        .description("התזכורות הקרובות שלך — בהצצה.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Root view

struct RemindersWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: RemindersEntry

    var body: some View {
        switch family {
        case .systemSmall:  RemindersSmall(entry: entry)
        case .systemMedium: RemindersMedium(entry: entry)
        case .systemLarge:  RemindersLarge(entry: entry)
        default:            RemindersMedium(entry: entry)
        }
    }
}

// MARK: - Small

/// Compact "count + next" view. Acts as a glanceable status indicator:
/// "you have 4 reminders, the next one is in 25m".
private struct RemindersSmall: View {
    let entry: RemindersEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetSectionLabel(icon: "bell.fill", text: "תזכורות")

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.reminders.count)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetBrand.heroGradient)
                    .monospacedDigit()
                Text(entry.reminders.count == 1 ? "פעילה" : "פעילות")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetBrand.muted)
            }

            Spacer(minLength: 0)

            if let next = entry.reminders.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.task)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetBrand.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill")
                            .font(.caption2.weight(.bold))
                        Text(next.dueDate, style: .relative)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    }
                    .foregroundStyle(next.isOverdue ? WidgetBrand.danger : WidgetBrand.indigo)
                }
            } else {
                Text("הכל מטופל 🌿")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WidgetBrand.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Medium

/// Top 3 reminders, each on its own row. Most-imminent first; an overdue
/// reminder gets a red pill and a danger-tinted clock.
private struct RemindersMedium: View {
    let entry: RemindersEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetSectionLabel(icon: "bell.fill", text: "התזכורות הקרובות")
                Spacer()
                Text("\(entry.reminders.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(WidgetBrand.indigo)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(WidgetBrand.indigo.opacity(0.12)))
            }

            if entry.reminders.isEmpty {
                allClearRow
            } else {
                VStack(spacing: 6) {
                    ForEach(entry.reminders.prefix(3)) { r in
                        ReminderRow(reminder: r, compact: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var allClearRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(WidgetBrand.mint)
                .font(.title3)
            Text("כל התזכורות מטופלות 🌿")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WidgetBrand.ink)
            Spacer()
        }
    }
}

// MARK: - Large

/// Up to 6 reminders grouped by "today / tomorrow / later" so the user
/// reads the widget like a structured agenda, not a flat list. Empty
/// groups are dropped.
private struct RemindersLarge: View {
    let entry: RemindersEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WidgetSectionLabel(icon: "bell.fill", text: "תזכורות")
                Spacer()
                Text("\(entry.reminders.count) פעילות")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetBrand.muted)
            }

            if entry.reminders.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(WidgetBrand.mint)
                        Text("כל התזכורות מטופלות")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WidgetBrand.ink)
                        Text("רגוע ויפה.")
                            .font(.caption)
                            .foregroundStyle(WidgetBrand.muted)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                grouped
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var grouped: some View {
        let groups = groupedReminders(entry.reminders.prefix(6).map { $0 })
        VStack(alignment: .leading, spacing: 10) {
            if !groups.today.isEmpty {
                section(title: "היום", reminders: groups.today)
            }
            if !groups.tomorrow.isEmpty {
                section(title: "מחר", reminders: groups.tomorrow)
            }
            if !groups.later.isEmpty {
                section(title: "בהמשך", reminders: groups.later)
            }
        }
    }

    private func section(title: String, reminders: [Reminder]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(WidgetBrand.muted)
                .textCase(.uppercase)
            VStack(spacing: 4) {
                ForEach(reminders) { r in
                    ReminderRow(reminder: r, compact: false)
                }
            }
        }
    }

    private struct Groups {
        var today: [Reminder]
        var tomorrow: [Reminder]
        var later: [Reminder]
    }

    private func groupedReminders(_ list: [Reminder]) -> Groups {
        let cal = Calendar.current
        var today: [Reminder] = []
        var tomorrow: [Reminder] = []
        var later: [Reminder] = []
        for r in list {
            if cal.isDateInToday(r.dueDate) { today.append(r) }
            else if cal.isDateInTomorrow(r.dueDate) { tomorrow.append(r) }
            else { later.append(r) }
        }
        return Groups(today: today, tomorrow: tomorrow, later: later)
    }
}

// MARK: - Row

private struct ReminderRow: View {
    let reminder: Reminder
    let compact: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                Circle()
                    .fill((reminder.isOverdue ? WidgetBrand.danger : WidgetBrand.indigo).opacity(0.14))
                    .frame(width: compact ? 22 : 24, height: compact ? 22 : 24)
                Image(systemName: reminder.isOverdue ? "exclamationmark" : "bell.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(reminder.isOverdue ? WidgetBrand.danger : WidgetBrand.indigo)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.task)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(WidgetBrand.ink)
                    .lineLimit(1)
                Text(reminder.dueDate, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(reminder.isOverdue ? WidgetBrand.danger : WidgetBrand.muted)
            }
            Spacer(minLength: 0)
        }
    }
}
