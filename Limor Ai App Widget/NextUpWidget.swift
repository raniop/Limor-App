import SwiftUI
import WidgetKit

// MARK: - Entry

struct NextUpEntry: TimelineEntry {
    let date: Date
    let primary: NextItem?
    let secondary: NextItem?
    let isPlaceholder: Bool

    static let placeholder = NextUpEntry(
        date: Date(),
        primary: .meeting(
            title: "פגישה עם דני",
            location: "תל אביב",
            when: Date().addingTimeInterval(45 * 60),
            isStartingSoon: true
        ),
        secondary: .reminder(
            task: "להוציא כביסה",
            when: Date().addingTimeInterval(3 * 3600),
            isOverdue: false
        ),
        isPlaceholder: true
    )
}

/// "Next thing on your plate" — either a reminder or a meeting. Kept as a
/// flat enum so the view doesn't have to branch on optional types and the
/// layout reads naturally for either.
enum NextItem: Hashable {
    case reminder(task: String, when: Date, isOverdue: Bool)
    case meeting(title: String, location: String?, when: Date, isStartingSoon: Bool)

    var when: Date {
        switch self {
        case let .reminder(_, when, _):    return when
        case let .meeting(_, _, when, _):  return when
        }
    }

    var title: String {
        switch self {
        case let .reminder(task, _, _): return task
        case let .meeting(title, _, _, _): return title
        }
    }

    var icon: String {
        switch self {
        case .reminder(_, _, let overdue):
            return overdue ? "exclamationmark.triangle.fill" : "bell.fill"
        case .meeting: return "calendar"
        }
    }

    var typeLabel: String {
        switch self {
        case .reminder:  return "תזכורת"
        case .meeting:   return "פגישה"
        }
    }

    var isUrgent: Bool {
        switch self {
        case let .reminder(_, _, overdue):   return overdue
        case let .meeting(_, _, _, soon):    return soon
        }
    }

    var urgentLabel: String? {
        switch self {
        case .reminder(_, _, let overdue):   return overdue ? "באיחור" : nil
        case .meeting(_, _, _, let soon):    return soon ? "מתחיל בקרוב" : nil
        }
    }
}

// MARK: - Provider

struct NextUpProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextUpEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (NextUpEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder); return
        }
        Task {
            let entry = await load()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextUpEntry>) -> Void) {
        Task {
            let entry = await load()
            // Refresh more aggressively than 30 min — "next up" decays
            // fast: a meeting that was 20 min away 10 min ago is now 10
            // min away and the urgent badge should flip.
            let nextRefresh = Date().addingTimeInterval(10 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    /// Merge cached reminders + cached meetings + the live `next_reminder`
    /// from `WidgetAPI.fetchNow`, pick the two with the earliest
    /// `when ≥ now`. Meetings that haven't ended yet still count as
    /// "upcoming" — the user often needs the reminder *during* the event.
    private func load() async -> NextUpEntry {
        let now = Date()
        var items: [NextItem] = []

        // Reminders — local cache; the live snapshot's `next_reminder`
        // adds the most up-to-date one.
        let reminders = SharedStore.loadReminders()
            .filter { $0.status == .pending }
        for r in reminders {
            items.append(.reminder(
                task: r.task,
                when: r.dueDate,
                isOverdue: r.isOverdue
            ))
        }
        if let live = await WidgetAPI.fetchNow()?.next_reminder {
            items.append(.reminder(
                task: live.task,
                when: live.dueDate,
                isOverdue: live.isOverdue
            ))
        }

        // Meetings — local calendar cache.
        for m in SharedStore.loadMeetings() {
            guard let start = ISO8601DateFormatter.limor.date(from: m.start_at)
                  ?? ISO8601DateFormatter().date(from: m.start_at) else { continue }
            let end = ISO8601DateFormatter.limor.date(from: m.end_at)
                  ?? ISO8601DateFormatter().date(from: m.end_at)
                  ?? start.addingTimeInterval(3600)
            // Drop events that already ended.
            if end < now { continue }
            // Don't show all-day "Jerusalem Day"-type entries as the
            // primary "next thing" — they swamp the actual meetings.
            if m.is_all_day { continue }
            items.append(.meeting(
                title: m.title,
                location: m.location,
                when: start,
                isStartingSoon: start.timeIntervalSinceNow > 0 && start.timeIntervalSinceNow < 15 * 60
            ))
        }

        let sorted = items
            .filter { $0.when.timeIntervalSinceNow > -5 * 60 } // tolerate 5min overdue
            .sorted { $0.when < $1.when }

        // Dedup: a reminder and a meeting with the same title within 5min
        // are almost certainly the same thing.
        let deduped = Self.dedup(sorted)

        return NextUpEntry(
            date: now,
            primary: deduped.first,
            secondary: deduped.dropFirst().first,
            isPlaceholder: false
        )
    }

    private static func dedup(_ items: [NextItem]) -> [NextItem] {
        var out: [NextItem] = []
        for item in items {
            let duplicate = out.contains { existing in
                existing.title.trimmingCharacters(in: .whitespaces) == item.title.trimmingCharacters(in: .whitespaces)
                && abs(existing.when.timeIntervalSince(item.when)) < 5 * 60
            }
            if !duplicate { out.append(item) }
        }
        return out
    }
}

// MARK: - Widget

struct NextUpWidget: Widget {
    let kind: String = "NextUpWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextUpProvider()) { entry in
            NextUpWidgetView(entry: entry)
                .limorWidgetContainer()
        }
        .configurationDisplayName("הדבר הבא")
        .description("מה שמחכה לך כרגע — פגישה או תזכורת — לפי הסדר.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Root view

struct NextUpWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NextUpEntry

    var body: some View {
        if let primary = entry.primary {
            switch family {
            case .systemSmall:  NextUpSmall(primary: primary)
            case .systemMedium: NextUpMedium(primary: primary, secondary: entry.secondary)
            default:            NextUpMedium(primary: primary, secondary: entry.secondary)
            }
        } else {
            EmptyState()
        }
    }
}

private struct NextUpSmall: View {
    let primary: NextItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: primary.icon)
                    .font(.caption2.weight(.bold))
                Text(primary.typeLabel)
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 0)
                if let urgent = primary.urgentLabel {
                    WidgetPill(text: urgent, color: .white, filled: false)
                }
            }
            .foregroundStyle(.white.opacity(0.95))

            Text(primary.title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                Text(primary.when, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .limorHeroBlock(cornerRadius: 14)
    }
}

private struct NextUpMedium: View {
    let primary: NextItem
    let secondary: NextItem?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            primaryColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            if let secondary {
                secondaryColumn(secondary)
                    .frame(width: 110, alignment: .leading)
            }
        }
    }

    private var primaryColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: primary.icon)
                    .font(.caption.weight(.bold))
                Text(primary.typeLabel)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if let urgent = primary.urgentLabel {
                    WidgetPill(text: urgent, color: .white, filled: false)
                }
            }
            .foregroundStyle(.white.opacity(0.95))

            Text(primary.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Label {
                    Text(primary.when, style: .relative)
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock.fill")
                }
                if case .meeting(_, let loc, _, _) = primary, let loc, !loc.isEmpty {
                    Label {
                        Text(loc)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "location.fill")
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .limorHeroBlock(cornerRadius: 16)
    }

    private func secondaryColumn(_ item: NextItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetSectionLabel(icon: item.icon, text: "אחר כך")
            Text(item.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetBrand.ink)
                .lineLimit(2)
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text(item.when, style: .relative)
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(item.isUrgent ? WidgetBrand.danger : WidgetBrand.indigo)

            if case .meeting(_, let loc, _, _) = item, let loc, !loc.isEmpty {
                Text(loc)
                    .font(.caption2)
                    .foregroundStyle(WidgetBrand.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundStyle(WidgetBrand.mint)
            Text("הזמן שלך פנוי")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(WidgetBrand.ink)
            Text("אין פגישות או תזכורות קרובות.")
                .font(.caption)
                .foregroundStyle(WidgetBrand.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
