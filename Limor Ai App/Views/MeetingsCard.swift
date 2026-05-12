import SwiftUI

/// Home-feed card showing the next few upcoming events from the user's iOS
/// calendar. Reads directly from `CalendarManager` (EventKit) regardless of
/// which source is selected in Settings — the iOS Calendar already
/// aggregates events from Apple, Google, and Outlook accounts the user
/// has added at the OS level, so this is the friendliest "what's next"
/// without any backend round-trip.
struct MeetingsCard: View {
    @StateObject private var calendar = CalendarManager.shared
    @State private var events: [CalendarEventDTO] = []
    @State private var loadedOnce = false

    /// Show this many in the card body; the rest live behind "כל הפגישות".
    private let displayLimit = 3

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel(icon: "calendar.badge.clock", title: "הפגישות הבאות שלי")
                    Spacer()
                    if events.count > displayLimit {
                        Text("\(events.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorIndigo)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))
                    }
                }

                if !calendar.hasAccess {
                    accessRow
                } else if events.isEmpty && loadedOnce {
                    emptyRow
                } else if events.isEmpty {
                    loadingRow
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(events.prefix(displayLimit))) { ev in
                            MeetingRow(event: ev)
                        }
                    }
                }
            }
        }
        .task { await reload() }
        .onChange(of: calendar.hasAccess) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        if !calendar.hasAccess {
            _ = await calendar.requestAccess()
        }
        guard calendar.hasAccess else {
            loadedOnce = true
            return
        }
        let now = Date()
        // Pull a wide range, then sort by start ascending. EventKit returns
        // events in calendar-natural order; we want strict chronological so
        // "next" is unambiguous.
        let raw = calendar.fetchUpcomingEvents(daysAhead: 30)
        events = raw
            .filter { dto in
                guard let end = parseIso(dto.end_at) else { return false }
                return end > now
            }
            .sorted { lhs, rhs in
                (parseIso(lhs.start_at) ?? .distantFuture) < (parseIso(rhs.start_at) ?? .distantFuture)
            }
        loadedOnce = true
    }

    private func parseIso(_ s: String) -> Date? {
        ISO8601DateFormatter.limor.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private var accessRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.limorMuted)
            Text("צריך גישה ליומן — אפשר לאשר בהגדרות → הרשאות")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(.limorSuccess)
            Text("אין פגישות ב-30 הימים הקרובים")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.limorIndigo)
            Text("טוען…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MeetingRow: View {
    let event: CalendarEventDTO

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            dateBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(timeRange)
                        .font(.caption)
                }
                .foregroundStyle(.limorMuted)

                if let loc = event.location, !loc.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.caption2)
                        Text(loc).font(.caption).lineLimit(1)
                    }
                    .foregroundStyle(.limorMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.limorIndigo.opacity(0.06))
        )
    }

    private var dateBadge: some View {
        let date = parseIso(event.start_at) ?? Date()
        let cal = Calendar.current
        let day = cal.component(.day, from: date)
        let month = monthName(for: date)

        return VStack(spacing: 0) {
            Text(month)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color.limorIndigo)
            Text("\(day)")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.limorInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.9))
        }
        .frame(width: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.limorIndigo.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var timeRange: String {
        if event.is_all_day { return "כל היום" }
        let start = parseIso(event.start_at) ?? Date()
        let end = parseIso(event.end_at) ?? start
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        let cal = Calendar.current
        let dayLabel: String
        if cal.isDateInToday(start) { dayLabel = "היום" }
        else if cal.isDateInTomorrow(start) { dayLabel = "מחר" }
        else {
            let df = DateFormatter()
            df.locale = Locale(identifier: "he_IL")
            df.dateFormat = "EEEE"
            dayLabel = df.string(from: start)
        }
        return "\(dayLabel) · \(f.string(from: start))–\(f.string(from: end))"
    }

    private func monthName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "MMM"
        return f.string(from: date).uppercased()
    }

    private func parseIso(_ s: String) -> Date? {
        ISO8601DateFormatter.limor.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
