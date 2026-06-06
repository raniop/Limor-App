import SwiftUI

/// Home-feed card showing the next few upcoming events. Reads through
/// `CalendarAggregator`, which merges every source enabled in the in-app
/// picker — Apple EventKit + Google + Outlook (Microsoft Graph) — so a
/// calendar connected via the in-app Microsoft flow shows here too, not just
/// in Limor's chat. Tap navigates to `MeetingsListView` for the full list.
struct MeetingsCard: View {
    @StateObject private var calendar = CalendarManager.shared
    @State private var events: [CalendarEventDTO] = []
    @State private var loadedOnce = false
    /// Reactively observe the same toggle MeetingsListView's toolbar
    /// changes — if the user flips birthdays on/off in the detail view,
    /// the home card refreshes the next time it's on screen.
    @AppStorage("limor.hideBirthdayEvents", store: SharedStore.appGroupDefaults)
    private var hideBirthdays: Bool = true

    private let displayLimit = 3

    var body: some View {
        NavigationLink(destination: MeetingsListView()) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
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
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                    }

                    if events.isEmpty && loadedOnce {
                        // Only nudge for EventKit access when Apple is an
                        // enabled source — a Graph-only (Outlook/Google) setup
                        // can be legitimately empty without any iOS permission.
                        if CalendarAggregator.needsAppleAccess { accessRow } else { emptyRow }
                    } else if events.isEmpty {
                        loadingRow
                    } else {
                        VStack(spacing: 4) {
                            ForEach(Array(events.prefix(displayLimit))) { ev in
                                CompactMeetingRow(event: ev)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task { await reload() }
        .onChange(of: calendar.hasAccess) { _, _ in Task { await reload() } }
        .onChange(of: hideBirthdays) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        await CalendarAggregator.ensureAppleAccessIfNeeded()
        let now = Date()
        // Aggregator returns events merged across all enabled sources,
        // already deduped and sorted by start time.
        events = await CalendarAggregator.upcomingEvents(daysAhead: 30)
            .filter { (MeetingsCard.parseIso($0.end_at) ?? .distantPast) > now }
        loadedOnce = true
    }

    static func parseIso(_ s: String) -> Date? {
        ISO8601DateFormatter.limor.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private var accessRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.limorMuted)
            Text("צריך גישה ליומן — אפשר לאשר בהגדרות → הרשאות")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(.limorSuccess)
            Text("אין פגישות ב-30 הימים הקרובים").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.limorIndigo).scaleEffect(0.7)
            Text("טוען…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compact one-line row

/// Single-line meeting representation: small date pill + title + optional
/// start time. All-day events skip the time entirely (the pill IS the info).
/// Designed for the home card where vertical space is tight.
struct CompactMeetingRow: View {
    let event: CalendarEventDTO

    var body: some View {
        HStack(spacing: 10) {
            DateChip(date: MeetingsCard.parseIso(event.start_at) ?? Date())
            Text(event.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.limorInk)
                .lineLimit(1)
            Spacer(minLength: 4)
            if !event.is_all_day {
                Text(startTime)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.limorMuted)
            }
        }
        .padding(.vertical, 6)
    }

    private var startTime: String {
        let date = MeetingsCard.parseIso(event.start_at) ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// Pill showing "היום" / "מחר" / "ר׳ 14.5" depending on how far out the date
/// is. Today is highlighted indigo, near-future is a soft tint, far-future
/// gets a neutral background so the eye lands on the imminent meetings.
struct DateChip: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(backgroundColor))
            .frame(minWidth: 56)
    }

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "היום" }
        if cal.isDateInTomorrow(date) { return "מחר" }
        // Within the same week — show weekday name (e.g. "ה׳")
        let now = Date()
        if let days = cal.dateComponents([.day], from: now, to: date).day, days < 7 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "he_IL")
            f.dateFormat = "EEE"
            return f.string(from: date)
        }
        // Further out — short date "14.5"
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "d.M"
        return f.string(from: date)
    }

    private var backgroundColor: Color {
        Calendar.current.isDateInToday(date)
            ? Color.limorIndigo
            : Color.limorIndigo.opacity(0.12)
    }

    private var textColor: Color {
        Calendar.current.isDateInToday(date) ? .white : .limorIndigo
    }
}

// MARK: - Full-screen list

/// Dedicated screen showing every upcoming event with a bit more breathing
/// room than the home-feed preview. Sections by day so the user can scan.
struct MeetingsListView: View {
    @StateObject private var calendar = CalendarManager.shared
    @State private var events: [CalendarEventDTO] = []
    @State private var loaded = false
    /// Mirrors `SharedStore.hideBirthdayEvents` for a reactive toolbar
    /// toggle. Default true so users land in the cleaner view on first
    /// visit (lots of contact birthdays = noisy meetings list).
    @AppStorage("limor.hideBirthdayEvents", store: SharedStore.appGroupDefaults)
    private var hideBirthdays: Bool = true

    var body: some View {
        ZStack {
            LiquidBackdrop()
            if events.isEmpty && loaded {
                emptyState
            } else if events.isEmpty {
                ProgressView().tint(.limorIndigo)
            } else {
                ScrollView {
                    LazyVStack(spacing: 18, pinnedViews: []) {
                        ForEach(groupedByDay, id: \.0) { (dayKey, dayEvents) in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(dayKey)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.limorInk)
                                    .padding(.horizontal, 4)
                                VStack(spacing: 8) {
                                    ForEach(dayEvents) { ev in
                                        DetailedMeetingRow(event: ev)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("הפגישות הבאות שלי")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hideBirthdays.toggle()
                    Task { await reload() }
                } label: {
                    Image(systemName: hideBirthdays ? "birthday.cake" : "birthday.cake.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(hideBirthdays ? Color.limorMuted : Color.limorPink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.limorPink.opacity(hideBirthdays ? 0.05 : 0.18)))
                }
                .accessibilityLabel(hideBirthdays ? "הצג ימי הולדת" : "הסתר ימי הולדת")
            }
        }
        .task { await reload() }
        .onChange(of: hideBirthdays) { _, _ in Task { await reload() } }
    }

    private func reload() async {
        await CalendarAggregator.ensureAppleAccessIfNeeded()
        let now = Date()
        // Merged across every enabled source (EventKit + Google + Outlook),
        // deduped and sorted by the aggregator.
        events = await CalendarAggregator.upcomingEvents(daysAhead: 60)
            .filter { (MeetingsCard.parseIso($0.end_at) ?? .distantPast) > now }
        loaded = true
    }

    /// Group events by calendar day, preserving chronological order. Returns
    /// tuples instead of a dictionary so the day order is stable.
    private var groupedByDay: [(String, [CalendarEventDTO])] {
        let cal = Calendar.current
        var out: [(String, [CalendarEventDTO])] = []
        for ev in events {
            guard let start = MeetingsCard.parseIso(ev.start_at) else { continue }
            let key = dayLabel(for: start, calendar: cal)
            if let last = out.last, last.0 == key {
                out[out.count - 1].1.append(ev)
            } else {
                out.append((key, [ev]))
            }
        }
        return out
    }

    private func dayLabel(for date: Date, calendar cal: Calendar) -> String {
        if cal.isDateInToday(date) { return "היום" }
        if cal.isDateInTomorrow(date) { return "מחר" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "EEEE, d בMMMM"
        return f.string(from: date)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.limorMuted)
            Text("אין פגישות ב-60 הימים הקרובים")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.limorInk)
        }
    }
}

private struct DetailedMeetingRow: View {
    let event: CalendarEventDTO

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(Color.limorIndigo)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.caption2)
                    Text(timeText).font(.caption)
                }
                .foregroundStyle(.limorMuted)
                if let loc = event.location, !loc.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse").font(.caption2)
                        Text(loc).font(.caption).lineLimit(1)
                    }
                    .foregroundStyle(.limorMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var timeText: String {
        if event.is_all_day { return "כל היום" }
        let start = MeetingsCard.parseIso(event.start_at) ?? Date()
        let end = MeetingsCard.parseIso(event.end_at) ?? start
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return "\(f.string(from: start))–\(f.string(from: end))"
    }
}
