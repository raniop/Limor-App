import SwiftUI
import Charts

/// Tag breakdown of tasks over a time range — a pie chart + legend + summary.
/// Fully local (no backend, no tokens), computed only on appear / Refresh.
struct TaskAnalyticsView: View {
    let tasks: [LimorTask]
    /// Color for a tag — passed from TasksView so it matches the tag chips
    /// (including the user's manual color overrides).
    let colorFor: (String) -> Color

    @State private var range: AnalyticsRange = .week
    @State private var slices: [TagSlice] = []
    @State private var totalCount = 0
    @State private var computing = false
    @State private var lastUpdated: Date?

    private let untagged = tr("ללא תג", "Untagged")
    private var tint: Color { .limorIndigo }

    enum AnalyticsRange: String, CaseIterable, Identifiable {
        case today, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return tr("היום", "Today")
            case .week:  return tr("7 ימים", "7 days")
            case .month: return tr("30 יום", "30 days")
            }
        }
        var phrase: String {   // for the summary sentence
            switch self {
            case .today: return tr("היום", "today")
            case .week:  return tr("בשבוע האחרון", "in the past week")
            case .month: return tr("בחודש האחרון", "in the past month")
            }
        }
        var cutoff: Date {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week:  return Date().addingTimeInterval(-7 * 24 * 3600)
            case .month: return Date().addingTimeInterval(-30 * 24 * 3600)
            }
        }
    }

    struct TagSlice: Identifiable {
        var id: String { tag }
        let tag: String
        let count: Int
        let pct: Double
        let color: Color
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                rangePicker
                headerRow

                if computing {
                    ProgressView().tint(tint).frame(height: 220)
                } else if slices.isEmpty {
                    emptyState
                } else {
                    pieCard
                    legendCard
                    summaryCard
                }
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 28)
            .limorReadableWidth()
        }
        .task { if lastUpdated == nil { compute() } }
        .onChange(of: range) { _, _ in compute() }
    }

    // MARK: Controls

    private var rangePicker: some View {
        Picker(tr("טווח", "Range"), selection: $range) {
            ForEach(AnalyticsRange.allCases) { r in Text(r.label).tag(r) }
        }
        .pickerStyle(.segmented)
    }

    private var headerRow: some View {
        HStack {
            Button { compute() } label: {
                Label(tr("רענון", "Refresh"), systemImage: "arrow.clockwise").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(tint)
            Spacer()
            if let u = lastUpdated {
                Text(tr("עודכן \(timeText(u))", "Updated \(timeText(u))")).font(.caption2).foregroundStyle(.limorMuted)
            }
        }
    }

    // MARK: Pie + legend + summary

    private var pieCard: some View {
        GlassCard {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("משימות", slice.count),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.5
                )
                .cornerRadius(4)
                .foregroundStyle(slice.color)
            }
            .chartLegend(.hidden)
            .frame(height: 230)
            .overlay {
                VStack(spacing: 2) {
                    Text("\(totalCount)").font(.title2.weight(.bold)).foregroundStyle(.limorInk)
                    Text(tr("משימות", "tasks")).font(.caption2).foregroundStyle(.limorMuted)
                }
            }
        }
    }

    private var legendCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(slices) { slice in
                    HStack(spacing: 10) {
                        Circle().fill(slice.color).frame(width: 12, height: 12)
                        Text(slice.tag).font(.subheadline.weight(.semibold)).foregroundStyle(.limorInk)
                        Spacer()
                        Text("\(slice.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.limorMuted)
                        Text("\(Int(slice.pct.rounded()))%")
                            .font(.caption.weight(.bold)).foregroundStyle(slice.color)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        if let top = slices.first {
            GlassCard(tint: top.color) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(top.color)
                    Text(tr("\(range.phrase) רוב המשימות שלך היו תחת **\(top.tag)** — \(top.count) משימות, \(Int(top.pct.rounded()))% מכלל הפעילות.", "\(range.phrase) most of your tasks were under **\(top.tag)** — \(top.count) tasks, \(Int(top.pct.rounded()))% of all activity."))
                        .font(.subheadline).foregroundStyle(.limorInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyState: some View {
        LimorEmptyState(
            icon: "chart.pie",
            title: tr("אין עדיין מספיק נתונים", "Not enough data yet"),
            subtitle: tr("אין משימות עם תגיות בטווח הזמן הזה. הוסיפי משימות עם תגיות ונראה לך את הפילוח.", "No tagged tasks in this time range. Add tasks with tags and we'll show you the breakdown."),
            iconGradient: LimorGradient.brand
        )
        .padding(.top, 24)
    }

    // MARK: Compute (local, on demand)

    private func compute() {
        computing = true
        // The data is already in memory; the tiny delay just lets the loading
        // state show so the refresh reads as a real action.
        let cutoff = range.cutoff
        var counts: [String: Int] = [:]
        for task in tasks where task.createdDate >= cutoff {
            let tagsForTask = task.tags.isEmpty ? [untagged] : task.tags
            for t in tagsForTask { counts[t, default: 0] += 1 }
        }
        let total = counts.values.reduce(0, +)
        let built: [TagSlice] = counts
            .map { tag, count in
                TagSlice(
                    tag: tag,
                    count: count,
                    pct: total > 0 ? Double(count) / Double(total) * 100 : 0,
                    color: tag == untagged ? .limorMuted : colorFor(tag)
                )
            }
            .sorted { $0.count > $1.count }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            slices = built
            totalCount = total
            lastUpdated = Date()
            computing = false
        }
    }

    private func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
