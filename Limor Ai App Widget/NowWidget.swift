import SwiftUI
import WidgetKit

// MARK: - Entry

struct NowEntry: TimelineEntry {
    let date: Date
    let snapshot: NowResponse?
    /// Active shopping group, read from the App Group cache. Used as the
    /// secondary column in the home-screen sizes — the user prefers
    /// "what do I still need to buy?" over weather as the at-a-glance
    /// companion to the next reminder.
    let shopping: ShoppingGroup
    let isPlaceholder: Bool

    static let placeholder = NowEntry(
        date: Date(),
        snapshot: NowResponse(
            next_reminder: Reminder(
                id: "preview",
                task: "להתקשר לאמא",
                due_at: ISO8601DateFormatter.limor.string(from: Date().addingTimeInterval(3600)),
                status: .pending,
                created_at: ISO8601DateFormatter.limor.string(from: Date()),
                completed_at: nil,
                msUntilDue: 3600 * 1000,
                isOverdue: false
            ),
            weather: Weather(
                temp_c: 23, feels_like_c: 24,
                condition: "בהיר", icon: "sun.max.fill",
                high_c: 27, low_c: 18,
                fetched_at: ISO8601DateFormatter.limor.string(from: Date()),
                lat: 32.08, lng: 34.78
            ),
            user: NowResponse.User(display_name: "רני"),
            updated_at: ISO8601DateFormatter.limor.string(from: Date())
        ),
        shopping: ShoppingGroup(items: [
            ShoppingItem(name: "חלב 3%", completed: false),
            ShoppingItem(name: "לחם פרוס", completed: false),
            ShoppingItem(name: "ביצים L", completed: false),
            ShoppingItem(name: "אבוקדו", completed: true),
        ]),
        isPlaceholder: true
    )
}

// MARK: - Provider

struct NowProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder); return
        }
        Task {
            let snap = await WidgetAPI.fetchNow()
            completion(NowEntry(
                date: Date(),
                snapshot: snap,
                shopping: SharedStore.shoppingActiveGroup,
                isPlaceholder: false
            ))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
        Task {
            let snap = await WidgetAPI.fetchNow()
            let entry = NowEntry(
                date: Date(),
                snapshot: snap,
                shopping: SharedStore.shoppingActiveGroup,
                isPlaceholder: false
            )
            let nextRefresh = Date().addingTimeInterval(30 * 60) // 30 minutes
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

// MARK: - Widget

struct NowWidget: Widget {
    let kind: String = "NowWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowProvider()) { entry in
            NowWidgetView(entry: entry)
                .limorWidgetContainer()
        }
        .configurationDisplayName("עכשיו עם לימור")
        .description("התזכורת הקרובה ומזג האוויר במבט אחד.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

// MARK: - Root view

struct NowWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NowEntry

    var body: some View {
        switch family {
        case .systemSmall:        NowSmallView(entry: entry)
        case .systemMedium:       NowMediumView(entry: entry)
        case .systemLarge:        NowLargeView(entry: entry)
        case .accessoryRectangular: AccessoryRectangularView(entry: entry)
        case .accessoryCircular:    AccessoryCircularView(entry: entry)
        case .accessoryInline:      AccessoryInlineView(entry: entry)
        default:                   NowSmallView(entry: entry)
        }
    }
}

// MARK: - Small (home screen)

/// Two-row vertical layout: top row = reminder pill; bottom row = weather.
/// Optimised for a 158×158 tile — every element has breathing room and the
/// brand gradient frames the reminder so it pops at a glance.
private struct NowSmallView: View {
    let entry: NowEntry

    private var activeShopping: [ShoppingItem] {
        entry.shopping.items.filter { !$0.completed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = entry.snapshot?.next_reminder {
                reminderCard(r)
            } else {
                allClearCard
            }
            Spacer(minLength: 0)
            shoppingStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func reminderCard(_ r: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: r.isOverdue ? "exclamationmark.triangle.fill" : "bell.fill")
                    .font(.caption2.weight(.bold))
                Text(r.isOverdue ? "תזכורת באיחור" : "תזכורת הבאה")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.95))

            Text(r.task)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(r.dueDate, style: .relative)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .limorHeroBlock()
        .overlay(alignment: .topTrailing) {
            if r.isOverdue {
                WidgetPill(text: "באיחור", color: .white, filled: false)
                    .padding(8)
            }
        }
    }

    private var allClearCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2.weight(.bold))
                Text("הכל רגוע")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.95))

            Text("אין תזכורות פעילות")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .limorHeroBlock()
    }

    @ViewBuilder
    private var shoppingStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "cart.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(WidgetBrand.indigo)
            if activeShopping.isEmpty {
                Text("הרשימה ריקה")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetBrand.muted)
                    .lineLimit(1)
            } else {
                Text("\(activeShopping.count)")
                    .font(.body.weight(.bold).monospacedDigit())
                    .foregroundStyle(WidgetBrand.ink)
                Text(activeShopping.count == 1 ? "פריט" : "פריטים")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetBrand.muted)
                Spacer(minLength: 0)
                if let first = activeShopping.first {
                    Text(first.name)
                        .font(.caption2)
                        .foregroundStyle(WidgetBrand.ink.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

// MARK: - Medium (home screen)

/// Side-by-side: reminder hero on the trailing edge (RTL right), weather
/// card on the leading edge. Each gets ~half the width with a gentle
/// divider in between.
private struct NowMediumView: View {
    let entry: NowEntry

    private var activeShopping: [ShoppingItem] {
        entry.shopping.items.filter { !$0.completed }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            reminderColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            shoppingColumn
                .frame(width: 120, alignment: .leading)
        }
    }

    @ViewBuilder
    private var reminderColumn: some View {
        if let r = entry.snapshot?.next_reminder {
            // Flatter than the small/large variants — the medium widget
            // sits side-by-side with the shopping column on a shared
            // canvas, so a full purple gradient on this side looked like
            // a sticker pasted on the widget. We keep the indigo accent
            // bar + indigo type for hierarchy, but drop the gradient.
            HStack(alignment: .top, spacing: 8) {
                accentBar(overdue: r.isOverdue)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: r.isOverdue ? "exclamationmark.triangle.fill" : "bell.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(r.isOverdue ? WidgetBrand.danger : WidgetBrand.indigo)
                        Text(r.isOverdue ? "תזכורת באיחור" : "התזכורת הקרובה")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WidgetBrand.muted)
                        Spacer(minLength: 0)
                    }

                    Text(r.task)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(WidgetBrand.ink)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        Image(systemName: "clock.fill").font(.caption2.weight(.bold))
                        Text(r.dueDate, style: .relative)
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(r.isOverdue ? WidgetBrand.danger : WidgetBrand.indigo)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                WidgetSectionLabel(icon: "checkmark.seal.fill", text: "כל התזכורות מטופלות")
                Text("אין משימות פעילות 🌿")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WidgetBrand.ink)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func accentBar(overdue: Bool) -> some View {
        Capsule()
            .fill(overdue ? WidgetBrand.danger : WidgetBrand.indigo)
            .frame(width: 3)
    }

    @ViewBuilder
    private var shoppingColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetSectionLabel(icon: "cart.fill", text: "רשימת קניות")
            if activeShopping.isEmpty {
                Text("הרשימה ריקה ✨")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WidgetBrand.muted)
                    .padding(.top, 2)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(activeShopping.count)")
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(WidgetBrand.heroGradient)
                    Text(activeShopping.count == 1 ? "פריט" : "פריטים")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetBrand.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(activeShopping.prefix(3)) { item in
                        HStack(spacing: 4) {
                            Image(systemName: "circle")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(WidgetBrand.indigo)
                            Text(item.name)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(WidgetBrand.ink)
                                .lineLimit(1)
                        }
                    }
                    if activeShopping.count > 3 {
                        Text("+\(activeShopping.count - 3) נוספים")
                            .font(.caption2)
                            .foregroundStyle(WidgetBrand.muted)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - Large (home screen)

/// Stacked layout: header → reminder hero → weather row → footer.
/// Has room for a full reminder description + a structured weather
/// summary (current / high / low). Avoids `Divider()` so the spacing
/// matches the brand's softer look.
private struct NowLargeView: View {
    let entry: NowEntry

    private var activeShopping: [ShoppingItem] {
        entry.shopping.items.filter { !$0.completed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            greetingHeader
            reminderBlock
            shoppingBlock
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greetingHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(WidgetBrand.heroGradient)
                .font(.subheadline.weight(.bold))
            Text(greetingText)
                .font(.headline)
                .foregroundStyle(WidgetBrand.ink)
            Spacer(minLength: 0)
        }
    }

    private var greetingText: String {
        let name = entry.snapshot?.user.display_name ?? "רני"
        let hour = Calendar.current.component(.hour, from: Date())
        let prefix: String
        switch hour {
        case 5..<11:  prefix = "בוקר טוב"
        case 11..<17: prefix = "צהריים טובים"
        case 17..<22: prefix = "ערב טוב"
        default:      prefix = "לילה טוב"
        }
        return "\(prefix), \(name)"
    }

    @ViewBuilder
    private var reminderBlock: some View {
        if let r = entry.snapshot?.next_reminder {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: r.isOverdue ? "exclamationmark.triangle.fill" : "bell.fill")
                        .font(.caption.weight(.bold))
                    Text(r.isOverdue ? "תזכורת באיחור" : "התזכורת הקרובה")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    if r.isOverdue {
                        WidgetPill(text: "באיחור", color: .white, filled: false)
                    }
                }
                .foregroundStyle(.white.opacity(0.95))

                Text(r.task)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Label {
                        Text(r.dueDate, style: .relative)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "clock.fill")
                    }
                    Label {
                        Text(r.dueDate, style: .time)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "calendar")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .limorHeroBlock(cornerRadius: 16)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(WidgetBrand.mint)
                Text("כל התזכורות מטופלות")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WidgetBrand.ink)
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WidgetBrand.mint.opacity(0.12))
            )
        }
    }

    @ViewBuilder
    private var shoppingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetSectionLabel(icon: "cart.fill", text: "רשימת קניות")
                Spacer()
                if !activeShopping.isEmpty {
                    Text("\(activeShopping.count) לקנייה")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WidgetBrand.indigo)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(WidgetBrand.indigo.opacity(0.15)))
                }
            }
            if activeShopping.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(WidgetBrand.mint)
                    Text("הרשימה ריקה")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(WidgetBrand.ink)
                    Spacer()
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(activeShopping.prefix(5)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "circle")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(WidgetBrand.indigo)
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(WidgetBrand.ink)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    if activeShopping.count > 5 {
                        HStack {
                            Text("+\(activeShopping.count - 5) נוספים")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WidgetBrand.indigo)
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.6))
        )
    }

    @ViewBuilder
    private var footer: some View {
        if let updatedAt = entry.snapshot?.updated_at,
           let date = ISO8601DateFormatter.limor.date(from: updatedAt) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                Text("עודכן \(date, style: .relative)")
            }
            .font(.caption2)
            .foregroundStyle(WidgetBrand.muted)
        }
    }
}

// MARK: - Lock-screen accessories

private struct AccessoryRectangularView: View {
    let entry: NowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let r = entry.snapshot?.next_reminder {
                HStack(spacing: 4) {
                    Image(systemName: r.isOverdue ? "exclamationmark.triangle.fill" : "bell.fill")
                        .font(.caption2.weight(.bold))
                    Text(r.task)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(r.dueDate, style: .relative)
                    .font(.caption2.monospacedDigit())
            } else {
                Label("אין תזכורות", systemImage: "checkmark.seal.fill")
                    .font(.headline)
            }
            if let w = entry.snapshot?.weather {
                Label("\(Int(w.temp_c.rounded()))° · \(w.condition)", systemImage: w.icon)
                    .font(.caption2)
            }
        }
        .widgetAccentable()
    }
}

private struct AccessoryCircularView: View {
    let entry: NowEntry

    var body: some View {
        ZStack {
            // Always show a thin ring border so the widget reads on
            // ambient lock-screen backgrounds.
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 1)
            if let r = entry.snapshot?.next_reminder {
                VStack(spacing: 0) {
                    Image(systemName: r.isOverdue ? "exclamationmark.triangle.fill" : "bell.fill")
                        .font(.body)
                    if let mins = minutesUntil(r.dueDate) {
                        Text(mins)
                            .font(.caption2.weight(.bold).monospacedDigit())
                    }
                }
                .widgetAccentable()
            } else if let w = entry.snapshot?.weather {
                VStack(spacing: 0) {
                    Image(systemName: w.icon).font(.body)
                    Text("\(Int(w.temp_c.rounded()))°").font(.caption2.weight(.semibold))
                }
                .widgetAccentable()
            } else {
                Image(systemName: "sparkles").font(.body).widgetAccentable()
            }
        }
    }

    /// Compact relative time like "5d" / "2h" / "23m" — chosen by the
    /// largest unit that has a non-zero value, so the lock-screen circle
    /// never overflows.
    private func minutesUntil(_ date: Date) -> String? {
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return "!" }
        let mins = Int(interval / 60)
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

private struct AccessoryInlineView: View {
    let entry: NowEntry

    var body: some View {
        if let r = entry.snapshot?.next_reminder {
            Label("\(r.task)", systemImage: r.isOverdue ? "exclamationmark.triangle.fill" : "bell.fill")
        } else if let w = entry.snapshot?.weather {
            Text("\(Int(w.temp_c.rounded()))° · \(w.condition)")
        } else {
            Label("לימור", systemImage: "sparkles")
        }
    }
}
