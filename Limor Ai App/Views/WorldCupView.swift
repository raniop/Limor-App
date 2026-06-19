import SwiftUI

/// Tournament window gating: the tab shows only while the World Cup is
/// relevant (a few days before kickoff until shortly after the final).
enum WorldCupSeason {
    static var isActive: Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jerusalem") ?? .current
        guard let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 8)),
              let end = cal.date(from: DateComponents(year: 2026, month: 7, day: 22)) else { return false }
        let now = Date()
        return now >= start && now <= end
    }
}

/// מונדיאל 2026 — schedule + results tab. Data comes from the backend's
/// global bundle (Claude + web_search refreshes it server-side); this view
/// just groups matches by day and renders them.
struct WorldCupView: View {
    @State private var bundle: WorldCupBundle?
    @State private var loadedOnce = false
    @State private var refreshing = false

    private var matches: [WorldCupMatch] { bundle?.matches ?? [] }

    private var liveMatches: [WorldCupMatch] { matches.filter(\.isLive) }
    private var finishedMatches: [WorldCupMatch] {
        matches.filter(\.isFinished)
            .sorted { ($0.kickoffDate ?? .distantPast) > ($1.kickoffDate ?? .distantPast) }
    }
    private var upcomingMatches: [WorldCupMatch] {
        // A match is over ~2.5h after kickoff. The global bundle refreshes only
        // a couple of times a day, so a finished match's `status` is often
        // still stale — also drop anything whose kickoff is already well in the
        // past, or games that already ended keep showing as "upcoming".
        let cutoff = Date().addingTimeInterval(-2.5 * 3600)
        return matches
            .filter { !$0.isLive && !$0.isFinished && ($0.kickoffDate ?? .distantFuture) >= cutoff }
            .sorted { ($0.kickoffDate ?? .distantFuture) < ($1.kickoffDate ?? .distantFuture) }
    }

    /// Upcoming matches bucketed by local calendar day, in day order.
    private var upcomingByDay: [(day: Date, matches: [WorldCupMatch])] {
        let cal = Calendar.current
        let pairs: [(Date, WorldCupMatch)] = upcomingMatches.compactMap { m in
            guard let d = m.kickoffDate else { return nil }
            return (cal.startOfDay(for: d), m)
        }
        return Dictionary(grouping: pairs, by: \.0)
            .map { (day: $0.key, matches: $0.value.map(\.1)) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        ZStack {
            LiquidBackdrop().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    heroCard

                    if !liveMatches.isEmpty {
                        sectionCard(title: tr("משחקים עכשיו", "Live now"), icon: "dot.radiowaves.left.and.right", tint: .limorCoral, matches: liveMatches)
                    }

                    ForEach(upcomingByDay.prefix(6), id: \.day) { group in
                        sectionCard(title: dayTitle(group.day), icon: "calendar", tint: .limorIndigo, matches: group.matches)
                    }

                    if !finishedMatches.isEmpty {
                        sectionCard(title: tr("תוצאות אחרונות", "Recent results"), icon: "checkmark.circle.fill", tint: .limorMint, matches: Array(finishedMatches.prefix(6)))
                    }

                    if loadedOnce && matches.isEmpty {
                        GlassCard {
                            Text(tr("עוד אין נתוני משחקים. לימור תעדכן את הלוח בקרוב — אפשר גם למשוך לרענון.", "No match data yet. Limor will update the schedule soon — you can also pull to refresh."))
                                .font(.subheadline)
                                .foregroundStyle(.limorMuted)
                        }
                    } else if !loadedOnce {
                        ProgressView().tint(.limorIndigo).frame(height: 200)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await reload(force: true) }
        }
        .navigationTitle(tr("מונדיאל 2026", "World Cup 2026"))
        .navigationBarTitleDisplayMode(.large)
        .task { await initialLoad() }
    }

    // MARK: Hero

    private var heroCard: some View {
        GlassCard(tint: Color(red: 0.20, green: 0.66, blue: 0.62)) {
            HStack(spacing: 14) {
                Text("⚽️")
                    .font(.system(size: 44))
                VStack(alignment: .leading, spacing: 4) {
                    Text("FIFA World Cup 2026")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.limorInk)
                    Text(tr("ארה״ב · קנדה · מקסיקו", "USA · Canada · Mexico"))
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                    if let next = upcomingMatches.first, let date = next.kickoffDate {
                        Text(tr("המשחק הבא: \(next.home_team) – \(next.away_team) · \(relativeDay(date)) ב-\(timeText(date))", "Next match: \(next.home_team) – \(next.away_team) · \(relativeDay(date)) at \(timeText(date))"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.limorIndigo)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Sections

    private func sectionCard(title: String, icon: String, tint: Color, matches: [WorldCupMatch]) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: icon, title: title, tint: tint)
                ForEach(matches) { match in
                    WorldCupMatchRow(match: match)
                    if match.id != matches.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func initialLoad() async {
        guard !loadedOnce else { return }
        if DemoMode.isOn {
            bundle = DemoData.worldCup
            loadedOnce = true
            return
        }
        bundle = try? await APIClient.shared.getWorldCup()
        loadedOnce = true
        // Cheap server-side no-op when the global bundle is fresh; regenerates
        // when stale so the first user of the morning warms it for everyone.
        await reload(force: false)
    }

    private func reload(force: Bool) async {
        guard !DemoMode.isOn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if let fresh = try? await APIClient.shared.refreshWorldCup(force: force) {
            bundle = fresh
        }
    }

    // MARK: Formatting

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return tr("היום", "Today") }
        if cal.isDateInTomorrow(day) { return tr("מחר", "Tomorrow") }
        let f = DateFormatter()
        f.locale = AppLangBox.current.locale
        f.dateFormat = tr("EEEE, d בMMMM", "EEEE, MMMM d")
        return f.string(from: day)
    }

    private func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return tr("היום", "Today") }
        if cal.isDateInTomorrow(date) { return tr("מחר", "Tomorrow") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Home card

/// "מונדיאל 2026" — home-feed card: live match (with score) or the next
/// fixture, flags front and center. Tapping pushes the full WorldCupView.
/// Rendered by NowView only during the tournament window.
struct WorldCupCard: View {
    @ObservedObject private var sync = SyncManager.shared
    @State private var bundle: WorldCupBundle?
    @State private var loadedOnce = false

    private var tint: Color { HomeCardKind.worldCup.tint }

    private var liveMatch: WorldCupMatch? {
        bundle?.matches.first(where: \.isLive)
    }
    private var nextMatch: WorldCupMatch? {
        // Skip games already over (~2.5h past kickoff) even if the stale bundle
        // still marks them "scheduled" — otherwise "next match" shows a result.
        let cutoff = Date().addingTimeInterval(-2.5 * 3600)
        return bundle?.matches
            .filter { !$0.isLive && !$0.isFinished && ($0.kickoffDate ?? .distantFuture) >= cutoff }
            .sorted { ($0.kickoffDate ?? .distantFuture) < ($1.kickoffDate ?? .distantFuture) }
            .first
    }
    private var todayCount: Int {
        let cal = Calendar.current
        return (bundle?.matches ?? []).filter { m in
            guard let d = m.kickoffDate else { return false }
            return cal.isDateInToday(d) && !m.isFinished
        }.count
    }

    var body: some View {
        NavigationLink {
            WorldCupView()
        } label: {
            GlassCard(tint: tint) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel(icon: HomeCardKind.worldCup.icon, title: tr("מונדיאל 2026", "World Cup 2026"), tint: tint)
                        Spacer()
                        if liveMatch != nil {
                            HStack(spacing: 4) {
                                Circle().fill(Color.limorCoral).frame(width: 6, height: 6)
                                Text(tr("חי", "Live"))
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.limorCoral)
                            }
                        }
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                    }

                    if let match = liveMatch ?? nextMatch {
                        matchStrip(match)
                        footer(for: match)
                    } else if loadedOnce {
                        Text(tr("לוח המשחקים בדרך — לימור מעדכנת אותו ברגעים אלו ⚽️", "The match schedule is on its way — Limor is updating it right now ⚽️"))
                            .font(.subheadline)
                            .foregroundStyle(.limorMuted)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().tint(tint)
                            Text(tr("טוענת את לוח המשחקים…", "Loading the match schedule…"))
                                .font(.subheadline)
                                .foregroundStyle(.limorMuted)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task { await load() }
        // A home full-refresh regenerated the global bundle — pick it up
        // without requiring the user to open the detail page.
        .onChange(of: sync.lastGlobalCardsRefresh) { _, _ in
            Task {
                if !DemoMode.isOn,
                   let fresh = try? await APIClient.shared.getWorldCup(),
                   !fresh.matches.isEmpty {
                    bundle = fresh
                }
            }
        }
    }

    private func matchStrip(_ match: WorldCupMatch) -> some View {
        HStack(spacing: 12) {
            teamColumn(match.home_flag, match.home_team)
            VStack(spacing: 2) {
                if match.isLive {
                    Text("\(match.home_score ?? 0) : \(match.away_score ?? 0)")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.limorInk)
                        .environment(\.layoutDirection, .leftToRight)
                } else if let date = match.kickoffDate {
                    Text(timeText(date))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    Text(relativeDay(date))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.limorMuted)
                }
            }
            .frame(width: 80)
            teamColumn(match.away_flag, match.away_team)
        }
        .frame(maxWidth: .infinity)
    }

    private func teamColumn(_ flag: String?, _ name: String) -> some View {
        VStack(spacing: 4) {
            Text(flag ?? "🏳️").font(.system(size: 34))
            Text(name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.limorInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func footer(for match: WorldCupMatch) -> some View {
        HStack(spacing: 6) {
            Text(match.group.map { tr("\(match.stage) · בית \($0)", "\(match.stage) · Group \($0)") } ?? match.stage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.limorMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.limorInk.opacity(0.06)))
            Spacer(minLength: 0)
            if todayCount > 1 {
                Text(tr("\(todayCount) משחקים היום", "\(todayCount) matches today"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
    }

    private func load() async {
        guard !loadedOnce else { return }
        if DemoMode.isOn {
            bundle = DemoData.worldCup
            loadedOnce = true
            return
        }
        bundle = try? await APIClient.shared.getWorldCup()
        loadedOnce = true
        // Warm the global bundle when it's empty/stale — server cooldown makes
        // this a cheap no-op most of the time.
        if (bundle?.matches ?? []).isEmpty,
           let fresh = try? await APIClient.shared.refreshWorldCup(force: false) {
            bundle = fresh
        }
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return tr("היום", "Today") }
        if cal.isDateInTomorrow(date) { return tr("מחר", "Tomorrow") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }
}

// MARK: - Match row

private struct WorldCupMatchRow: View {
    let match: WorldCupMatch

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                team(match.home_flag, match.home_team, alignment: .leading)
                centerColumn
                team(match.away_flag, match.away_team, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Text(stageText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.limorMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.limorInk.opacity(0.06)))
                if let venue = match.venue {
                    Text(venue)
                        .font(.caption2)
                        .foregroundStyle(.limorMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private var stageText: String {
        if let g = match.group, !g.isEmpty { return tr("\(match.stage) · בית \(g)", "\(match.stage) · Group \(g)") }
        return match.stage
    }

    private func team(_ flag: String?, _ name: String, alignment: HorizontalAlignment) -> some View {
        VStack(spacing: 3) {
            Text(flag ?? "🏳️")
                .font(.system(size: 28))
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.limorInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var centerColumn: some View {
        VStack(spacing: 2) {
            if match.isLive || match.isFinished {
                Text("\(match.home_score ?? 0) : \(match.away_score ?? 0)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.limorInk)
                    .environment(\.layoutDirection, .leftToRight)
                if match.isLive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.limorCoral).frame(width: 6, height: 6)
                        Text(tr("חי", "Live"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.limorCoral)
                    }
                } else {
                    Text(tr("סיום", "Final"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.limorMuted)
                }
            } else if let date = match.kickoffDate {
                Text(kickoffTime(date))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.limorIndigo)
                Text(tr("שעון ישראל", "Israel time"))
                    .font(.caption2)
                    .foregroundStyle(.limorMuted)
            } else {
                Text("—").foregroundStyle(.limorMuted)
            }
        }
        .frame(width: 86)
    }

    private func kickoffTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
