import SwiftUI
import WidgetKit

// MARK: - Entry

struct ShoppingEntry: TimelineEntry {
    let date: Date
    let group: ShoppingGroup
    let isPlaceholder: Bool

    static let placeholder = ShoppingEntry(
        date: Date(),
        group: ShoppingGroup(items: [
            ShoppingItem(name: "חלב 3% תנובה",   completed: false),
            ShoppingItem(name: "לחם פרוס",       completed: false),
            ShoppingItem(name: "ביצים L 12 יחי׳", completed: false),
            ShoppingItem(name: "אבוקדו",          completed: true),
            ShoppingItem(name: "עגבניות שרי",      completed: false),
        ]),
        isPlaceholder: true
    )
}

// MARK: - Provider

struct ShoppingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShoppingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ShoppingEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder); return
        }
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ShoppingEntry>) -> Void) {
        let entry = load()
        let nextRefresh = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func load() -> ShoppingEntry {
        ShoppingEntry(date: Date(), group: SharedStore.shoppingActiveGroup, isPlaceholder: false)
    }
}

// MARK: - Widget

struct ShoppingWidget: Widget {
    let kind: String = "ShoppingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ShoppingProvider()) { entry in
            ShoppingWidgetView(entry: entry)
                .limorWidgetContainer()
        }
        .configurationDisplayName("רשימת קניות")
        .description("הפריטים הפעילים ברשימת הקניות שלך.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Root view

struct ShoppingWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: ShoppingEntry

    private var active: [ShoppingItem] {
        entry.group.items.filter { !$0.completed }
    }

    private var doneCount: Int {
        entry.group.items.filter { $0.completed }.count
    }

    var body: some View {
        switch family {
        case .systemSmall:  small
        case .systemMedium: medium
        case .systemLarge:  large
        default:            medium
        }
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetSectionLabel(icon: "cart.fill", text: "קניות")

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(active.count)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetBrand.heroGradient)
                    .monospacedDigit()
                Text(active.count == 1 ? "פריט" : "פריטים")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetBrand.muted)
            }

            Spacer(minLength: 0)

            if active.isEmpty {
                Text("הרשימה ריקה ✨")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WidgetBrand.muted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(active.prefix(2)) { item in
                        Text("• \(item.name)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WidgetBrand.ink)
                            .lineLimit(1)
                    }
                    if active.count > 2 {
                        Text("+\(active.count - 2) נוספים")
                            .font(.caption2)
                            .foregroundStyle(WidgetBrand.muted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Medium

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WidgetSectionLabel(icon: "cart.fill", text: "רשימת הקניות")
                Spacer()
                if doneCount > 0 {
                    Text("\(doneCount) סומנו")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WidgetBrand.mint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(WidgetBrand.mint.opacity(0.15)))
                }
                Text("\(active.count) לקנייה")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetBrand.indigo)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(WidgetBrand.indigo.opacity(0.15)))
            }

            if active.isEmpty {
                emptyState
            } else {
                // 2-column grid of items so we fit more in medium without
                // each line truncating. Limits to 6 cells; "+N נוספים"
                // fills the last cell if we have more.
                let visible = Array(active.prefix(5))
                let overflow = max(0, active.count - 5)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                    ForEach(visible) { item in
                        itemCell(item)
                    }
                    if overflow > 0 {
                        Text("+\(overflow) נוספים")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WidgetBrand.indigo)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Large

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WidgetSectionLabel(icon: "cart.fill", text: "רשימת הקניות")
                Spacer()
                progressPill
            }

            if active.isEmpty && doneCount == 0 {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "cart")
                            .font(.system(size: 36))
                            .foregroundStyle(WidgetBrand.indigo.opacity(0.6))
                        Text("הרשימה ריקה")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WidgetBrand.ink)
                        Text("תגיד ללימור מה לקנות.")
                            .font(.caption)
                            .foregroundStyle(WidgetBrand.muted)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                if !active.isEmpty {
                    Text("לקנות")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(WidgetBrand.muted)
                        .textCase(.uppercase)
                    VStack(spacing: 4) {
                        ForEach(active.prefix(8)) { item in
                            itemRow(item, done: false)
                        }
                        if active.count > 8 {
                            Text("+\(active.count - 8) נוספים")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(WidgetBrand.indigo)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                        }
                    }
                }
                let donePreview = entry.group.items.filter { $0.completed }.prefix(2)
                if !donePreview.isEmpty {
                    Text("נסגרו")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(WidgetBrand.muted)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                    VStack(spacing: 4) {
                        ForEach(donePreview) { item in
                            itemRow(item, done: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Bits

    private var progressPill: some View {
        let total = entry.group.items.count
        let percent = total == 0 ? 0 : Int(Double(doneCount) / Double(total) * 100)
        return HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(WidgetBrand.mint)
            Text("\(percent)%")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(WidgetBrand.ink)
        }
    }

    private func itemCell(_ item: ShoppingItem) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "circle")
                .font(.caption2.weight(.bold))
                .foregroundStyle(WidgetBrand.indigo)
            Text(item.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetBrand.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func itemRow(_ item: ShoppingItem, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.body.weight(.bold))
                .foregroundStyle(done ? WidgetBrand.mint : WidgetBrand.indigo)
            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(done ? WidgetBrand.muted : WidgetBrand.ink)
                .strikethrough(done, color: WidgetBrand.muted)
                .lineLimit(1)
            Spacer()
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "cart")
                .foregroundStyle(WidgetBrand.indigo.opacity(0.6))
                .font(.title3)
            Text("הרשימה ריקה — תגיד ללימור מה לקנות")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(WidgetBrand.ink)
            Spacer()
        }
    }
}
