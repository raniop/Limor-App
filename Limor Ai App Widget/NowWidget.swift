import SwiftUI
import WidgetKit

// MARK: - Entry

struct NowEntry: TimelineEntry {
    let date: Date
    let snapshot: NowResponse?
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
            completion(NowEntry(date: Date(), snapshot: snap, isPlaceholder: false))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) {
        Task {
            let snap = await WidgetAPI.fetchNow()
            let entry = NowEntry(date: Date(), snapshot: snap, isPlaceholder: false)
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
                .containerBackground(.fill.tertiary, for: .widget)
                .environment(\.layoutDirection, .rightToLeft)
        }
        .configurationDisplayName("עכשיו")
        .description("התזכורת הבאה ומזג האוויר.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline,
        ])
    }
}

// MARK: - View

struct NowWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: NowEntry

    var body: some View {
        switch family {
        case .systemSmall: SmallView(entry: entry)
        case .systemMedium: MediumView(entry: entry)
        case .systemLarge: LargeView(entry: entry)
        case .accessoryRectangular: AccessoryRectangularView(entry: entry)
        case .accessoryCircular: AccessoryCircularView(entry: entry)
        case .accessoryInline: AccessoryInlineView(entry: entry)
        default: SmallView(entry: entry)
        }
    }
}

private struct SmallView: View {
    let entry: NowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = entry.snapshot?.next_reminder {
                Label("תזכורת", systemImage: "bell.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(r.task)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(r.dueDate, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(r.isOverdue ? .red : .secondary)
            } else {
                Text("אין תזכורות 🌿")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let w = entry.snapshot?.weather {
                HStack(spacing: 4) {
                    Image(systemName: w.icon)
                    Text("\(Int(w.temp_c.rounded()))°")
                }
                .font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MediumView: View {
    let entry: NowEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("התזכורת הבאה", systemImage: "bell.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let r = entry.snapshot?.next_reminder {
                    Text(r.task)
                        .font(.headline)
                        .lineLimit(2)
                    Text(r.dueDate, style: .relative)
                        .font(.caption)
                        .foregroundStyle(r.isOverdue ? .red : .secondary)
                } else {
                    Text("אין תזכורות פעילות").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("מזג אוויר", systemImage: "cloud.sun.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let w = entry.snapshot?.weather {
                    HStack(spacing: 6) {
                        Image(systemName: w.icon).font(.title2)
                        Text("\(Int(w.temp_c.rounded()))°").font(.title2.weight(.semibold))
                    }
                    Text(w.condition).font(.caption)
                    if let high = w.high_c, let low = w.low_c {
                        Text("\(Int(low.rounded()))° / \(Int(high.rounded()))°")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 110, alignment: .leading)
        }
    }
}

private struct LargeView: View {
    let entry: NowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MediumView(entry: entry)
            Divider()
            if let r = entry.snapshot?.next_reminder {
                VStack(alignment: .leading, spacing: 4) {
                    Text("פירוט התזכורת").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(r.task).font(.body.weight(.semibold))
                    Text(r.dueDate, style: .date).font(.caption).foregroundStyle(.secondary)
                    Text(r.dueDate, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let updatedAt = entry.snapshot?.updated_at,
               let date = ISO8601DateFormatter.limor.date(from: updatedAt) {
                Text("עודכן: \(date, style: .relative)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccessoryRectangularView: View {
    let entry: NowEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let r = entry.snapshot?.next_reminder {
                Text(r.task).font(.headline).lineLimit(1)
                Text(r.dueDate, style: .relative).font(.caption2)
            } else {
                Text("אין תזכורות").font(.headline)
            }
            if let w = entry.snapshot?.weather {
                Label("\(Int(w.temp_c.rounded()))°", systemImage: w.icon).font(.caption2)
            }
        }
    }
}

private struct AccessoryCircularView: View {
    let entry: NowEntry

    var body: some View {
        if let w = entry.snapshot?.weather {
            VStack(spacing: 0) {
                Image(systemName: w.icon).font(.body)
                Text("\(Int(w.temp_c.rounded()))°").font(.caption2.weight(.semibold))
            }
        } else {
            Image(systemName: "bell.fill").font(.body)
        }
    }
}

private struct AccessoryInlineView: View {
    let entry: NowEntry

    var body: some View {
        if let r = entry.snapshot?.next_reminder {
            Label("\(r.task)", systemImage: "bell.fill")
        } else if let w = entry.snapshot?.weather {
            Text("\(Int(w.temp_c.rounded()))° \(w.condition)")
        } else {
            Text("לימור")
        }
    }
}
