import SwiftUI
import UniformTypeIdentifiers

struct NowView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    /// .regular on iPad (and large landscape) → multi-column card grid.
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @StateObject private var location = LocationManager.shared
    @StateObject private var health = HealthManager.shared
    @StateObject private var sync = SyncManager.shared
    @State private var snapshot: NowResponse?
    @State private var allReminders: [Reminder] = []
    @State private var insights: InsightsBundle?
    @State private var feed: FeedBundle = FeedBundle(topics: [], items: [], generated_at: nil)
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cardOrder: [HomeCardKind] = HomeCardOrder.load()
    @State private var hiddenCards: Set<HomeCardKind> = HomeCardOrder.loadHidden()
    @State private var showingCustomize = false
    /// Throttle for the auto (foreground / app-entry) full refresh.
    @State private var lastAutoFullRefresh: Date = .distantPast
    /// The card currently being dragged for long-press reorder.
    @State private var draggedCard: HomeCardKind?
    /// Which pending reminder is showing on the home hero. Re-clamped on
    /// every render so a complete/snooze can't leave it past the new
    /// last card.
    @State private var reminderHeroIndex: Int = 0
    /// Which flight is currently shown on the hero flight card. Bumped by
    /// horizontal swipe / page-dot tap on the card; reset to 0 whenever
    /// the underlying list changes so a deletion doesn't leave the
    /// pointer past the end.
    @State private var flightHeroIndex: Int = 0
    /// Set when the user taps the upcoming-flight card to inspect the
    /// original booking email. Drives the `.sheet(item:)` that shows
    /// `FlightDetailView`.
    @State private var flightDetail: FlightInsight?
    /// Set when the user taps "בוצע" on the home-screen reminder hero —
    /// drives a confirmation dialog before actually completing. The hero
    /// is a fat button at the top of the scroll view and was getting
    /// stray-tapped during scrolls; the dialog cuts that out without
    /// forcing the user into the Reminders tab to undo.
    @State private var pendingCompleteFromHero: Reminder?

    /// Bumped by the toolbar refresh button → the ScrollView scrolls to the
    /// top so the refresh is visibly "doing something".
    @State private var scrollToTopNonce = UUID()

    private var tod: LimorTimeOfDay { .current }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                // Pin the scroll column to the exact viewport width and clip
                // anything that draws past it. This is a *global* guarantee
                // that the home screen can only ever scroll vertically — no
                // decorative blur, offset circle, over-wide row, or future
                // card can leak past the edge and trick the ScrollView into
                // panning sideways. (We used to chase each offending element
                // with its own .clipShape; this caps the whole column once so
                // the bug can't return from a new source.) Clipping at the
                // viewport edge only removes off-screen overflow, so nothing
                // visible — card shadows included — is affected.
                GeometryReader { geo in
                    ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            greetingHeader
                                .id("homeTop")
                            limorStatusChip
                                .animation(.easeInOut(duration: 0.25), value: sync.chipState)
                            cardLayout(width: geo.size.width)

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(Capsule().fill(Color.limorDanger.opacity(0.9)))
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                        // Cap the column at ~700pt on iPhone; on iPad let the
                        // grid use the full detail width (up to ~1400). Never
                        // wider than the viewport (preserves the iPhone layout +
                        // no-horizontal-scroll guarantee).
                        .frame(width: min(geo.size.width, hSizeClass == .regular ? 1400 : 700))
                        .frame(width: geo.size.width)
                        .clipped()
                    }
                    // The toolbar refresh button bumps this nonce — scroll
                    // back to the top so the user actually SEES the status
                    // chip and the cards updating instead of wondering
                    // whether the tap did anything.
                    .onChange(of: scrollToTopNonce) { _, _ in
                        withAnimation(.easeInOut(duration: 0.35)) {
                            scrollProxy.scrollTo("homeTop", anchor: .top)
                        }
                    }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ProfileAvatar(photoB64: auth.photoB64, size: 36, bordered: false)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showingCustomize = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.limorInk)
                        }
                        Button {
                            scrollToTopNonce = UUID()
                            Task { await fullRefresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.limorInk)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingCustomize) {
                CustomizeHomeSheet(
                    currentOrder: cardOrder,
                    currentHidden: hiddenCards
                ) { newOrder, newHidden in
                    cardOrder = newOrder
                    hiddenCards = newHidden
                    HomeCardOrder.save(newOrder)
                    HomeCardOrder.saveHidden(newHidden)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $flightDetail) { flight in
                FlightDetailView(flight: flight, hotel: hotel(for: flight))
                    .environment(\.layoutDirection, .rightToLeft)
                    .environment(\.locale, Locale(identifier: "he_IL"))
            }
            .confirmationDialog(
                tr("לסמן כבוצע?", "Mark as done?"),
                isPresented: Binding(
                    get: { pendingCompleteFromHero != nil },
                    set: { if !$0 { pendingCompleteFromHero = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingCompleteFromHero
            ) { r in
                // No `message:` closure — long reminder text was stretching
                // the dialog half-way up the screen. The card sits right
                // behind the dialog so the user can already see which
                // reminder is being acted on.
                Button(tr("סמן כבוצע", "Mark as done"), role: .none) {
                    let target = r
                    pendingCompleteFromHero = nil
                    Task { await completeNextReminder(target) }
                }
                Button(tr("ביטול", "Cancel"), role: .cancel) {
                    pendingCompleteFromHero = nil
                }
            }
            .refreshable { await fullRefresh() }
            .onChange(of: sync.lastInsightsRefresh) { _, _ in
                // Backend just finished extracting insights — pull the new
                // snapshot so the flight card appears without a tab switch.
                Task { await reload() }
            }
            .task {
                if DemoMode.isOn { seedDemo(); return }
                // Show last cached snapshot immediately so the screen isn't blank
                // while we hit the network.
                if snapshot == nil, let cached = SharedStore.loadLastNow() {
                    snapshot = cached
                }
                location.requestWhenInUseAndStart()
                _ = await health.requestAccess()
                await health.loadToday()
                // App entry → refresh everything (throttle-respecting) and
                // settle into the stamped "רעננתי לך הכל ✨ · היום HH:mm" line.
                await fullRefresh(forced: false)
            }
            .onChange(of: location.coordinate?.latitude) { _, _ in
                Task { await reload() }
            }
            // Returning to the home tab — re-pull so a reminder Limor just
            // created in chat (or any other backend change) shows on the
            // hero immediately, instead of staying stale until the next
            // app foreground. In a TabView the root view stays alive, so
            // `.task` doesn't re-run on tab switches — this fills that gap.
            .onChange(of: router.selectedTab) { _, newTab in
                guard newTab == .now else { return }
                Task { await reload() }
            }
            // Auto-refresh the news feed whenever the user returns to the
            // App foreground → refresh everything (cooldown-respecting).
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                // Every time the app comes to the foreground → full refresh
                // (throttle-respecting) so the user always sees the freshest
                // data plus the "רעננתי לך הכל ✨ · היום HH:mm" confirmation.
                Task { await fullRefresh(forced: false) }
            }
            // Periodic poll while the user stays on the screen — the
            // backend regenerates the feed on its own schedule, so a
            // cheap `getFeed()` is enough to pick up new items without
            // forcing a fresh LLM pass every couple of minutes.
            .onReceive(Timer.publish(every: 90, on: .main, in: .common).autoconnect()) { _ in
                Task {
                    if let fresh = try? await APIClient.shared.getFeed() {
                        feed = fresh
                    }
                }
            }
        }
    }

    // MARK: Limor background-activity status

    /// Subtle chip under the greeting: while Limor scans email / hunts
    /// flights / triages tasks it shows what she's doing; when the batch
    /// finishes it settles into a friendly "done" line that persists (so
    /// the user sees she finished) until the next activity starts.
    /// A thin gradient highlight that sweeps left→right forever — an
    /// indeterminate progress bar for the status chip.
    private struct IndeterminateBar: View {
        let tint: Color
        @State private var animate = false

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                Capsule()
                    .fill(LinearGradient(
                        colors: [tint.opacity(0), tint, tint.opacity(0)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * 0.45)
                    .offset(x: animate ? w * 1.0 : -w * 0.45)
            }
            .frame(height: 3)
            .background(tint.opacity(0.14))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
        }
    }

    @ViewBuilder
    private var limorStatusChip: some View {
        switch sync.chipState {
        case .idle:
            EmptyView()
        case .working(let label):
            statusChip(icon: "sparkles", text: tr("לימור \(label)…", "Limor \(label)…"), tint: .limorViolet, working: true)
        case .done(let label):
            statusChip(icon: "checkmark.circle.fill", text: label, tint: .limorSuccess, working: false)
        }
    }

    private func statusChip(icon: String, text: String, tint: Color, working: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: working)
                // Text crossfades in place so the label swap doesn't reflow the row.
                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.limorInk)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // A sweeping indeterminate bar at the bottom edge while working —
            // reads as "something's happening" far better than a tiny spinner.
            if working {
                IndeterminateBar(tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.18), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Fade in/out without shifting the cards below — no vertical move.
        // The driving .animation lives at the call site (keyed to chipState).
        .transition(.opacity)
    }

    // MARK: Greeting

    private var greetingHeader: some View {
        let name = snapshot?.user.display_name ?? auth.displayName
        return VStack(alignment: .leading, spacing: 4) {
            // HStack with greeting first, weather indicator second — in RTL
            // the greeting reads from the right and the visual sits on the
            // left, matching the user's expectation. The weather icon
            // replaces the generic time-of-day emoji whenever we have a
            // current snapshot — sunny → sun.max.fill, cloudy → cloud.fill,
            // matches what the user actually sees outside.
            HStack(spacing: 6) {
                Text(tod.greeting)
                if let weather = snapshot?.weather {
                    Image(systemName: weather.icon)
                        .symbolRenderingMode(.multicolor)
                        .imageScale(.medium)
                } else {
                    Text(tod.emoji)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.limorMuted)

            Text(name?.isEmpty == false ? name! : tr("שלום", "Hello"))
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.limorInk)
        }
    }

    // MARK: Card dispatch (drives user-customizable order)

    /// Home card layout. iPhone → single column. iPad/wide → a dashboard: the
    /// next-reminder hero spans full width, everything else fills a guaranteed
    /// 2-column (3 on very wide) grid. Extracted from `body` so the type
    /// checker doesn't choke on the giant scroll-content expression.
    @ViewBuilder
    private func cardLayout(width: CGFloat) -> some View {
        let visible = cardOrder.filter { !hiddenCards.contains($0) }
        if hSizeClass == .regular {
            // Every card — including the next-reminder hero — packs into a TRUE
            // masonry (each drops into the currently-shortest column) → zero
            // gaps, and the hero is a normal column-width card instead of a
            // giant full-width banner. Long-press drag reorders the sequence.
            let columns = width > 1150 ? 3 : 2
            MasonryLayout(columns: columns, spacing: 18) {
                ForEach(visible) { card in
                    reorderableCard(card)
                }
            }
        } else {
            // iPhone: direct on-screen drag was tried three ways (system
            // .onDrag, SwiftUI gestures, a UIKit recognizer) and none felt
            // right inside this ScrollView. Long-press opens the customize
            // sheet instead — via the system context menu, NOT a SwiftUI
            // LongPressGesture: a gesture on every card made the scroll
            // intermittently unresponsive (it competed for every touch),
            // while the UIKit context-menu interaction coexists cleanly.
            ForEach(visible) { card in
                cardView(for: card)
                    .contextMenu {
                        Button {
                            showingCustomize = true
                        } label: {
                            Label(tr("סדר את המסך הראשי", "Arrange home screen"), systemImage: "arrow.up.arrow.down")
                        }
                    }
            }
        }
    }

    /// A home card with long-press-drag reorder. The next-reminder hero is
    /// excluded — it has its own horizontal swipe gesture.
    @ViewBuilder
    private func reorderableCard(_ card: HomeCardKind) -> some View {
        if card == .nextReminder {
            cardView(for: card)
        } else {
            cardView(for: card)
                .onDrag {
                    draggedCard = card
                    return NSItemProvider(object: card.rawValue as NSString)
                } preview: {
                    cardView(for: card).frame(width: 320).opacity(0.9)
                }
                .onDrop(
                    of: [.text],
                    delegate: CardReorderDrop(
                        target: card,
                        order: $cardOrder,
                        dragged: $draggedCard,
                        onCommit: { HomeCardOrder.save(cardOrder) }
                    )
                )
        }
    }

    @ViewBuilder
    private func cardView(for card: HomeCardKind) -> some View {
        switch card {
        case .nextReminder:    nextReminderHero
        case .recommendations: recommendationsCard
        case .meetings:        MeetingsCard()
        case .tasks:           TasksCard()
        case .emailActions:    EmailActionsCard()
        case .feed:            feedCard
        case .nextFlight:      nextFlightCard
        case .worldCup:        worldCupCard
        case .briefing:        BriefingCard()
        case .expenses:        expensesCard
        case .weather:         weatherCard
        case .shopping:        ShoppingListCard()
        case .health:          healthCard
        case .stats:           statsRow
        }
    }

    // MARK: Hero — next reminder

    /// Lightweight parser for a reminder's task text. Pulls out a time
    /// (which already appears in the meta strip and would otherwise
    /// double up: "תור לרופא, שעה 15:00" + a 15:00 chip) and an
    /// address-shaped trailing fragment (street + number, or a known
    /// city name) so the title reads cleaner. Heuristic only — no
    /// natural-language parser. When in doubt we leave the original
    /// text alone rather than mangle it.
    private static func parseReminder(_ task: String) -> (task: String, address: String?) {
        var s = task

        // 1. Strip time mentions. Covers the common Hebrew patterns
        //    we've seen Claude emit when it creates reminders:
        //      "בשעה 15:00" / "שעה 15:00" / "ב-15:00" / "ב 15:00"
        //    The optional leading comma + spaces gets eaten with it so
        //    we don't leave a dangling "," at the end.
        let timePatterns = [
            #"\s*[,،]?\s*(?:ב\s*שעה|בשעה|שעה|ב[-־]?)\s*\d{1,2}:\d{2}"#,
        ]
        for pattern in timePatterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // 2. Try to peel off a trailing address. We split on commas /
        //    em-dashes and check the last piece — if it looks like a
        //    street+number or contains a recognised city name we lift
        //    it out and leave the rest as the task title.
        var address: String? = nil
        let separators: [Character] = [",", "،", "—"]
        if let lastSepIdx = s.lastIndex(where: { separators.contains($0) }) {
            let candidate = s[s.index(after: lastSepIdx)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeAddress(candidate) {
                address = candidate
                s = String(s[..<lastSepIdx])
            }
        }

        // Final cleanup — trim trailing punctuation/whitespace we left
        // behind ("X, " → "X").
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.—"))
        s = s.trimmingCharacters(in: trim)
        if let a = address { address = abbreviateCityNames(in: a) }
        return (s, address)
    }

    /// Swap long Hebrew city names for their standard abbreviations so a
    /// long street + city like "פינסקר 70 פתח תקווה" reads as
    /// "פינסקר 70 פ״ת" and fits cleanly in the meta chip.
    private static let cityAbbreviations: [(String, String)] = [
        ("תל אביב יפו", "ת״א"),
        ("תל אביב",     "ת״א"),
        ("פתח תקווה",   "פ״ת"),
        ("ראשון לציון", "ראשל״צ"),
        ("בני ברק",     "ב״ב"),
        ("רמת גן",      "ר״ג"),
        ("כפר סבא",     "כ״ס"),
        ("באר שבע",     "ב״ש"),
        ("ראש העין",    "ר״ע"),
        ("הוד השרון",   "ה״ש"),
        ("קריית גת",    "ק״ג"),
        ("בית שמש",     "ב״ש"),
    ]

    private static func abbreviateCityNames(in s: String) -> String {
        var out = s
        for (full, short) in cityAbbreviations {
            out = out.replacingOccurrences(of: full, with: short)
        }
        return out
    }

    private static let knownCities: Set<String> = [
        "תל אביב", "ירושלים", "חיפה", "באר שבע", "ראשון לציון",
        "פתח תקווה", "אשדוד", "אשקלון", "נתניה", "חולון", "בני ברק",
        "רמת גן", "גבעתיים", "הרצליה", "כפר סבא", "רעננה", "הוד השרון",
        "רחובות", "מודיעין", "רמלה", "לוד", "אילת", "קריית גת",
        "נצרת", "טבריה", "צפת", "עפולה", "כרמיאל", "עכו", "נהריה",
        "בית שמש", "גוש דן", "ראש העין",
    ]

    private static func looksLikeAddress(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 60 else { return false }
        // Reject if it looks like a name (no digits, no city)
        if knownCities.contains(where: { s.contains($0) }) { return true }
        // Otherwise require both a Hebrew letter AND a digit — that's
        // the signature of a street name with a house number.
        let hasDigit = s.contains(where: { $0.isNumber })
        let hasHebrew = s.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
        return hasDigit && hasHebrew
    }

    /// Decorative backdrop for the reminder hero: the brand/danger
    /// gradient, drop shadow, and the two offset glow circles. Rendered
    /// via `.background()` so the 180pt-wide circle can't dictate the
    /// outer card's height — that was the source of the asymmetric
    /// padding the user saw (extra space top and bottom).
    @ViewBuilder
    private func reminderHeroBackdrop(overdue: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(overdue ? LimorGradient.danger : LimorGradient.brand)
                .shadow(
                    color: (overdue ? Color.limorDanger : Color.limorIndigo).opacity(0.35),
                    radius: 24, y: 14
                )

            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: 180, height: 180)
                .offset(x: -60, y: -80)
                .blur(radius: 30)
            Circle()
                .fill((overdue ? Color.limorCoral : Color.limorPink).opacity(0.35))
                .frame(width: 140, height: 140)
                .offset(x: 200, y: 100)
                .blur(radius: 30)
        }
    }

    /// Centered date · time bar inside the reminder hero. Mirrors the
    /// flight card's compact meta strip so both heroes share the same
    /// visual rhythm (icon + value · separator · icon + value).
    private func metaLine(for r: Reminder, address: String? = nil) -> some View {
        // Year is implied for upcoming reminders — only show it when
        // the due date crosses into a different calendar year. Saves
        // ~45pt of width and lets the address chip share the row.
        let cal = Calendar.current
        let sameYear = cal.component(.year, from: r.dueDate) == cal.component(.year, from: Date())
        let dateFormat: Date.FormatStyle = sameYear
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year(.twoDigits)
        return HStack(spacing: 8) {
            HStack(spacing: 3) {
                Image(systemName: "clock.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
                Text(r.dueDate, style: .time)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Circle().fill(.white.opacity(0.35)).frame(width: 3, height: 3)
            HStack(spacing: 3) {
                Image(systemName: "calendar")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.72))
                Text(r.dueDate, format: dateFormat)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if let address, !address.isEmpty {
                Circle().fill(.white.opacity(0.35)).frame(width: 3, height: 3)
                HStack(spacing: 3) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(address)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
    }

    /// Slim primary/secondary action button used by the reminder hero.
    /// `primary` flips between a filled white background (calls-to-action
    /// like "בוצע") and an outlined white stroke (secondary like
    /// "נודניק"). Both are full-width and 36pt tall — less screen
    /// real-estate than the previous 12pt-vertical-padded buttons.
    private func actionLabel(systemImage: String, title: String, primary: Bool, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
            Text(title)
                .font(.subheadline.weight(primary ? .bold : .semibold))
        }
        .foregroundStyle(primary ? tint : .white)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            Group {
                if primary {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.95))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.55), lineWidth: 1.1)
                }
            }
        )
    }

    /// Compact navigation chevron for the reminder hero. Sits INSIDE
    /// the card on top of either an indigo or red gradient — the
    /// previous indigo-on-indigo styling melted into the background.
    /// White circle + tinted glyph gives full contrast against both
    /// card colours.
    private func heroNavChevron(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(.limorIndigo)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Pending reminders ordered for the home hero: overdue first (most
    /// urgent), then upcoming by ascending due time. Upcoming items are
    /// only surfaced once they're within a 48h window — anything farther
    /// out lives in the dedicated Reminders tab so the home feed stays
    /// focused on what's actually about to happen. Capped at 8 so the
    /// dots strip stays readable.
    private var heroReminders: [Reminder] {
        let pending = allReminders.filter { $0.status == .pending }
        let horizon = Date().addingTimeInterval(48 * 3600)
        let overdue = pending.filter { $0.isOverdue }.sorted { $0.dueDate < $1.dueDate }
        let upcoming = pending
            .filter { !$0.isOverdue && $0.dueDate <= horizon }
            .sorted { $0.dueDate < $1.dueDate }
        return Array((overdue + upcoming).prefix(8))
    }

    private var nextReminderHero: some View {
        Group {
            let recs = heroReminders
            if !recs.isEmpty {
                let safeIndex = max(0, min(reminderHeroIndex, recs.count - 1))
                let r = recs[safeIndex]
                let totalRecs = recs.count
                // Once a reminder is past its due time, swap the whole
                // hero's color scheme to the danger gradient so it
                // reads as "needs attention" at a glance — purple with
                // a small red pill wasn't loud enough.
                let overdue = r.isOverdue
                // Pull a trailing address + any inline "שעה HH:MM" out
                // of the task so the headline stays focused on the
                // action and the meta strip below carries date/time and
                // (optionally) the location.
                let parsed = Self.parseReminder(r.task)
                // Boarding-pass styled layout — same shape as the flight
                // card so the hero row reads as a consistent family.
                // Decorative gradient + glow circles ride in `.background`
                // rather than as ZStack siblings so a `Circle().frame(180)`
                // can't push the card to a 180pt minimum height (which
                // was leaving a dead band above and below the content
                // and making the padding look asymmetric).
                VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(.white.opacity(0.18)).frame(width: 32, height: 32)
                                Image(systemName: overdue ? "exclamationmark.triangle.fill" : "bell.fill")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(overdue ? tr("תזכורת באיחור", "Overdue reminder") : tr("התזכורת הבאה", "Next reminder"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                if overdue {
                                    Text(tr("דורש טיפול עכשיו", "Needs attention now"))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                            }
                            Spacer()
                            // Relative-time pill on the trailing edge —
                            // mirrors the "בעוד N ימים" pill on the
                            // flight card so the two heroes scan alike.
                            Text(r.dueDate, style: .relative)
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(.white.opacity(0.25)))
                        }

                        Text(parsed.task)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .minimumScaleFactor(0.85)
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Compact meta line — time, date and (optionally)
                        // the parsed-out location, all in a single chip
                        // strip so the hero stays short.
                        metaLine(for: r, address: parsed.address)

                        // Inline complete + snooze actions, slimmer than
                        // the previous full-bleed buttons.
                        HStack(spacing: 8) {
                            Button {
                                pendingCompleteFromHero = r
                            } label: {
                                actionLabel(systemImage: "checkmark.circle.fill", title: tr("בוצע", "Done"), primary: true, tint: overdue ? .limorDanger : .limorIndigo)
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task { await snoozeNextReminder(r, minutes: 10) }
                            } label: {
                                actionLabel(systemImage: "alarm", title: tr("נודניק 10'", "Snooze 10'"), primary: false, tint: .white)
                            }
                            .buttonStyle(.plain)
                        }

                        if totalRecs > 1 {
                            LimorPageDots(
                                count: totalRecs,
                                index: safeIndex,
                                activeColor: .white,
                                inactiveColor: .white
                            )
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, -2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    reminderHeroIndex = (safeIndex + 1) % totalRecs
                                }
                            }
                        }
                    }
                .padding(.horizontal, totalRecs > 1 ? 52 : 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { reminderHeroBackdrop(overdue: overdue) }
                // Side chevrons — inside the card, vertically centered,
                // 12pt from the edges. Sits behind the .gesture/.id
                // modifiers below but on top of the card content (the
                // 58pt horizontal padding on the inner VStack ensures
                // task text + action buttons don't bleed under them).
                .overlay(alignment: .trailing) {
                    if totalRecs > 1 {
                        heroNavChevron(systemName: "chevron.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                reminderHeroIndex = (safeIndex + 1) % totalRecs
                            }
                        }
                        .padding(.trailing, 12)
                    }
                }
                .overlay(alignment: .leading) {
                    if totalRecs > 1 {
                        heroNavChevron(systemName: "chevron.right") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                reminderHeroIndex = (safeIndex - 1 + totalRecs) % totalRecs
                            }
                        }
                        .padding(.leading, 12)
                    }
                }
                // Clip the decorative offset circles to the card shape.
                // Without this they render 60–200pt beyond the card's
                // logical bounds, and the parent ScrollView treats the
                // out-of-bounds drawing as scrollable horizontal content
                // — that's the root cause of the "home tab pans sideways
                // when a reminder is on screen" bug. Clipping fixes the
                // pan AND gives the decorative blurs the rounded mask
                // they visually needed anyway.
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .animation(.easeInOut(duration: 0.25), value: overdue)
                .id(r.id)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: r.id)
                // Swipe to advance — safe now that .clipShape stops the
                // decorative blurs from extending past the card and
                // tricking the parent ScrollView into thinking there's
                // horizontal content to scroll. Threshold guards keep
                // vertical scrolls flowing through to the ScrollView.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 16)
                        .onEnded { value in
                            guard totalRecs > 1 else { return }
                            let h = value.translation.width
                            let v = value.translation.height
                            guard abs(h) > abs(v), abs(h) > 40 else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                // RTL convention (mirrored from LTR's
                                // "swipe left = next"): swipe RIGHT
                                // reveals the next reminder (which lives
                                // to the left in RTL reading order),
                                // swipe LEFT goes back to the previous.
                                if h > 0 {
                                    reminderHeroIndex = (safeIndex + 1) % totalRecs
                                } else {
                                    reminderHeroIndex = (safeIndex - 1 + totalRecs) % totalRecs
                                }
                            }
                        }
                )

            } else if isLoading && snapshot == nil {
                // Only show the loading skeleton on the very first load, when we
                // have nothing to show yet. Once we have a snapshot, refreshes
                // keep the "all quiet" / reminder card in place so the layout
                // doesn't jump on every silent re-fetch.
                GlassCard {
                    HStack { ProgressView().tint(.limorIndigo); Text(tr("טוען…", "Loading…")).foregroundStyle(.secondary) }
                }
            } else {
                // The hero is filtered to a 48h window — but a user may
                // still have pending reminders farther out. Surface that
                // explicitly instead of saying "אין תזכורות פעילות"
                // (which is misleading when there are 5 pending next
                // week).
                let laterCount = allReminders
                    .filter { $0.status == .pending && !$0.isOverdue }
                    .count
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LimorGradient.mint.opacity(0.85))
                        .shadow(color: Color.limorMint.opacity(0.3), radius: 20, y: 10)
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 38))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(laterCount > 0 ? tr("פנוי ליומיים הקרובים 🌿", "Clear for the next two days 🌿") : tr("הכל רגוע 🌿", "All calm 🌿"))
                                .font(.title3.weight(.bold))
                            Text(laterCount > 0
                                 ? tr("\(laterCount) תזכורות בהמשך", "\(laterCount) reminders later")
                                 : tr("אין תזכורות פעילות", "No active reminders"))
                                .font(.subheadline)
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                }
                .frame(minHeight: 110)
            }
        }
    }

    // MARK: Weather

    @ViewBuilder
    private var weatherCard: some View {
        if let w = snapshot?.weather {
            NavigationLink {
                WeatherDetailView(lat: w.lat, lng: w.lng, cityName: location.cityName)
            } label: {
                weatherCardContent
            }
            .buttonStyle(.plain)
        } else {
            weatherCardContent
        }
    }

    private var weatherCardContent: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel(icon: "thermometer.medium", title: tr("מזג אוויר עכשיו", "Weather now"))
                    Spacer()
                    if let city = location.cityName {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill").font(.caption2)
                            Text(city).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.limorIndigo)
                    }
                    if snapshot?.weather != nil {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                    }
                }

                if let w = snapshot?.weather {
                    HStack(alignment: .center, spacing: 18) {
                        ZStack {
                            Circle().fill(weatherTint(w).opacity(0.15)).frame(width: 64, height: 64)
                            Image(systemName: w.icon)
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(weatherTint(w))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(w.temp_c.rounded()))°")
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(.limorInk)
                            Text(localizedWeatherCondition(w.condition))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let high = w.high_c, let low = w.low_c {
                            VStack(alignment: .trailing, spacing: 4) {
                                Label("\(Int(high.rounded()))°", systemImage: "arrow.up")
                                    .labelStyle(WeatherMinMaxLabel(tint: .limorCoral))
                                Label("\(Int(low.rounded()))°", systemImage: "arrow.down")
                                    .labelStyle(WeatherMinMaxLabel(tint: .limorIndigo))
                            }
                        }
                    }
                } else if location.authorizationStatus == .denied || location.authorizationStatus == .restricted {
                    HStack(spacing: 10) {
                        Image(systemName: "location.slash").foregroundStyle(.limorMuted)
                        Text(tr("אישור מיקום נדרש בהגדרות → לימור", "Location permission required in Settings → Limor"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else if location.coordinate != nil {
                    // We know WHERE the user is — the weather provider just
                    // didn't answer (e.g. Open-Meteo outage). Saying
                    // "מאתר מיקום" here was a lie that sent the user to
                    // debug location permissions.
                    HStack(spacing: 10) {
                        Image(systemName: "cloud.slash").foregroundStyle(.limorMuted)
                        Text(tr("שירות מזג האוויר לא זמין כרגע — ננסה שוב מיד", "Weather service is unavailable right now — we'll try again shortly"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().tint(.limorIndigo)
                        Text(tr("מאתר מיקום…", "Finding location…")).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func weatherTint(_ w: Weather) -> Color {
        if w.icon.contains("sun") { return .limorWarning }
        if w.icon.contains("cloud") && w.icon.contains("rain") { return .limorIndigo }
        if w.icon.contains("snow") { return .limorIndigo }
        if w.icon.contains("bolt") { return .limorViolet }
        return .limorIndigo
    }

    // MARK: AI recommendations (generated by backend on insights refresh)

    @ViewBuilder
    private var recommendationsCard: some View {
        let recs = (insights?.recommendations ?? [])
            .sorted { $0.priority < $1.priority }
        if !recs.isEmpty {
            RecommendationsCard(recommendations: recs)
        }
    }

    // MARK: Personal feed (user-curated topics + web_search updates)

    private var feedCard: some View {
        FeedCard(
            bundle: $feed,
            onRefresh: {
                do {
                    feed = try await APIClient.shared.refreshFeed(force: true)
                } catch {
                    errorMessage = error.localizedDescription
                }
            },
            onSaveTopics: { newTopics in
                do {
                    feed = try await APIClient.shared.setFeedTopics(newTopics)
                    // Trigger a fresh generation pass for the new topic set so
                    // the user doesn't sit on stale items from the old list.
                    feed = try await APIClient.shared.refreshFeed(force: true)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    // MARK: World Cup 2026 (tournament-window card)

    @ViewBuilder
    private var worldCupCard: some View {
        if WorldCupSeason.isActive {
            WorldCupCard()
        }
    }

    // MARK: Monthly expenses (receipts auto-extracted from email)

    @ViewBuilder
    private var expensesCard: some View {
        let receipts = insights?.receipts ?? []
        if let currentMonth = ExpenseMonth.group(receipts).first {
            NavigationLink {
                ExpensesDetailView(receipts: receipts)
            } label: {
                ExpensesCard(month: currentMonth)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Next flight (auto-detected from Gmail)

    @ViewBuilder
    private var nextFlightCard: some View {
        let flights = upcomingFlights
        if !flights.isEmpty {
            // Clamp the index so a refresh that drops a flight (Gmail
            // re-extraction, manual dismissal) can't leave us pointing
            // past the end.
            let safeIndex = max(0, min(flightHeroIndex, flights.count - 1))
            let flight = flights[safeIndex]
            let total = flights.count

            // No wrapping VStack — page dots live INSIDE FlightCard's
            // padded VStack, under the clipShape, so they neither look
            // detached nor leak layout past the card's edge.
            FlightCard(
                flight: flight,
                onDismiss: {
                    var ids = SharedStore.dismissedFlightIds
                    ids.insert(flight.id)
                    SharedStore.dismissedFlightIds = ids
                    if flightHeroIndex >= total - 1 {
                        flightHeroIndex = max(0, total - 2)
                    }
                    Task { await reload() }
                },
                position: total > 1 ? (safeIndex, total) : nil,
                onAdvance: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        flightHeroIndex = (safeIndex + 1) % total
                    }
                },
                hotel: hotel(for: flight)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                flightDetail = flight
            }
            // `highPriorityGesture` instead of `.gesture` — without it
            // the parent ScrollView's vertical pan recognizer wins
            // ties and the user's horizontal swipe sometimes nudges the
            // whole screen sideways before our handler ever fires. High
            // priority + a lower `minimumDistance` (16 not 24) lets the
            // card claim the swipe early. The threshold guard inside
            // still rejects motion that's mostly vertical.
            .highPriorityGesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        guard total > 1 else { return }
                        let h = value.translation.width
                        let v = value.translation.height
                        guard abs(h) > abs(v), abs(h) > 40 else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            // RTL: swipe right reveals the next flight.
                            if h > 0 {
                                flightHeroIndex = (safeIndex + 1) % total
                            } else {
                                flightHeroIndex = (safeIndex - 1 + total) % total
                            }
                        }
                    }
            )
        }
    }

    /// All future flights (not dismissed, not departed >1h ago), sorted
    /// by departure time. The hero card cycles through them via swipe /
    /// page-dot tap; previously we showed only the first.
    private var upcomingFlights: [FlightInsight] {
        guard let flights = insights?.flights else { return [] }
        let now = Date()
        let dismissed = SharedStore.dismissedFlightIds
        return flights
            .filter { !dismissed.contains($0.id) }
            .filter { ($0.departureDate ?? .distantPast) > now.addingTimeInterval(-3600) }
            .sorted { ($0.departureDate ?? .distantPast) < ($1.departureDate ?? .distantPast) }
    }

    /// The hotel matched to a given flight (linked by the backend via
    /// destination + dates or shared booking reference). When several stays
    /// matched the same flight, prefer the earliest check-in.
    private func hotel(for flight: FlightInsight) -> HotelInsight? {
        guard let hotels = insights?.hotels else { return nil }
        return hotels
            .filter { $0.matched_flight_id == flight.id }
            .sorted { ($0.checkInDate ?? .distantFuture) < ($1.checkInDate ?? .distantFuture) }
            .first
    }

    // MARK: Health

    @ViewBuilder
    private var healthCard: some View {
        if let h = health.summary, hasAnyHealth(h) {
            VStack(spacing: 14) {
                NavigationLink {
                    HealthDetailView(summary: h)
                } label: {
                    GlassCard(padding: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            // Header with chevron
                            HStack {
                                SectionLabel(icon: "heart.fill", title: tr("בריאות היום", "Today's health"))
                                Spacer()
                                Text("Apple Health")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.limorMuted)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.limorMuted.opacity(0.12)))
                                Image(systemName: "chevron.left")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.limorMuted)
                            }

                            // Activity pills — 2×2 LazyVGrid so each pill
                            // gets roughly half the row instead of a
                            // quarter. The earlier 1×4 HStack worked at
                            // default font size but at large Dynamic
                            // Type the labels ("דק' פעילות", "ש' עמידה")
                            // wrapped awkwardly and squeezed the digits.
                            if hasActivity(h) {
                                LazyVGrid(
                                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                    spacing: 8
                                ) {
                                    if let steps = h.steps {
                                        HealthStat(icon: "figure.walk", value: stepsString(steps), label: tr("צעדים", "Steps"), tint: .limorMint)
                                    }
                                    if let cals = h.active_calories_kcal, cals > 0 {
                                        HealthStat(icon: "flame.fill", value: "\(Int(cals.rounded()))", label: "kcal", tint: .limorCoral)
                                    }
                                    if let mins = h.exercise_minutes, mins > 0 {
                                        HealthStat(icon: "stopwatch.fill", value: "\(mins)", label: tr("דק' פעילות", "Active min"), tint: .limorViolet)
                                    }
                                    if let stand = h.stand_hours, stand > 0 {
                                        HealthStat(icon: "figure.stand", value: "\(stand)", label: tr("ש' עמידה", "Stand hrs"), tint: .limorIndigo)
                                    }
                                }
                            }

                            // Compact summary line: most important secondary metrics inline
                            let summary = compactSummary(h)
                            if !summary.isEmpty {
                                HStack(spacing: 14) {
                                    ForEach(summary) { item in
                                        HStack(spacing: 4) {
                                            Image(systemName: item.icon).foregroundStyle(item.tint)
                                            Text(item.text).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .font(.caption.weight(.medium))
                            }

                            // Tap hint
                            HStack(spacing: 4) {
                                Spacer()
                                Text(tr("הצג עוד", "Show more"))
                                    .font(.caption2.weight(.semibold))
                                Image(systemName: "arrow.left")
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(Color.limorIndigo)
                        }
                    }
                }
                .buttonStyle(.plain)

                if let workout = h.last_workout {
                    LastWorkoutCard(
                        workout: workout,
                        weekCount: h.workouts_this_week,
                        weekMinutes: h.workout_minutes_this_week
                    )
                }
            }
        } else if HKHealthAvailable() && !health.hasAccess {
            GlassCard {
                HStack(spacing: 12) {
                    Image(systemName: "heart.fill").foregroundStyle(.limorCoral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("חבר את Apple Health", "Connect Apple Health")).font(.subheadline.weight(.semibold))
                        Text(tr("ראי צעדים, קלוריות ועוד", "See steps, calories and more")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            _ = await health.requestAccess()
                            await health.loadToday()
                        }
                    } label: {
                        Text(tr("הפעל", "Enable"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(LimorGradient.brand))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func hasAnyHealth(_ h: HealthSummary) -> Bool {
        hasActivity(h) || !healthDetailRows(h).isEmpty || h.last_workout != nil
    }

    private func hasActivity(_ h: HealthSummary) -> Bool {
        (h.steps ?? 0) > 0
            || (h.active_calories_kcal ?? 0) > 0
            || (h.exercise_minutes ?? 0) > 0
            || (h.stand_hours ?? 0) > 0
    }

    private func stepsString(_ steps: Int) -> String {
        if steps >= 1000 {
            return String(format: "%.1fK", Double(steps) / 1000)
        }
        return "\(steps)"
    }

    /// Compact 2-3 secondary metrics shown on the NowView teaser.
    private func compactSummary(_ h: HealthSummary) -> [CompactHealthItem] {
        var items: [CompactHealthItem] = []
        if let rhr = h.resting_heart_rate {
            items.append(.init(icon: "heart.fill", text: "\(rhr) bpm", tint: .limorCoral))
        }
        if let sleep = h.sleep_hours, sleep > 0 {
            items.append(.init(icon: "moon.zzz.fill", text: String(format: "%.1fh", sleep), tint: .limorViolet))
        }
        if let dist = h.distance_km, dist > 0 {
            items.append(.init(icon: "map.fill", text: String(format: tr("%.1f ק\"מ", "%.1f km"), dist), tint: .limorIndigo))
        }
        return Array(items.prefix(3))
    }

    private func healthDetailRows(_ h: HealthSummary) -> [HealthDetailRowData] {
        var rows: [HealthDetailRowData] = []
        if let sleep = h.sleep_hours, sleep > 0 {
            rows.append(.init(icon: "moon.zzz.fill", label: tr("שינה אתמול", "Sleep last night"),
                              value: String(format: tr("%.1f שעות", "%.1f hrs"), sleep), tint: .limorViolet))
        }
        if let rhr = h.resting_heart_rate {
            rows.append(.init(icon: "heart.fill", label: tr("דופק במנוחה", "Resting heart rate"),
                              value: "\(rhr) bpm", tint: .limorCoral))
        }
        if let walking = h.walking_heart_rate_avg {
            rows.append(.init(icon: "figure.walk.motion", label: tr("דופק בהליכה", "Walking heart rate"),
                              value: "\(walking) bpm", tint: .limorCoral))
        }
        if let hrv = h.heart_rate_variability_ms {
            rows.append(.init(icon: "waveform.path.ecg", label: "HRV",
                              value: String(format: "%.0f ms", hrv), tint: .limorCoral))
        }
        if let dist = h.distance_km, dist > 0 {
            rows.append(.init(icon: "map.fill", label: tr("מרחק", "Distance"),
                              value: String(format: tr("%.2f ק\"מ", "%.2f km"), dist), tint: .limorIndigo))
        }
        if let vo2 = h.vo2_max {
            rows.append(.init(icon: "lungs.fill", label: "VO2 Max",
                              value: String(format: "%.1f", vo2), tint: .limorMint))
        }
        if let weight = h.weight_kg {
            rows.append(.init(icon: "scalemass.fill", label: tr("משקל", "Weight"),
                              value: String(format: tr("%.1f ק\"ג", "%.1f kg"), weight), tint: .limorIndigo))
        }
        if let bf = h.body_fat_percent, bf > 0 {
            rows.append(.init(icon: "drop.fill", label: tr("אחוז שומן", "Body fat"),
                              value: String(format: "%.1f%%", bf), tint: .limorViolet))
        }
        if let mindful = h.mindful_minutes, mindful > 0 {
            rows.append(.init(icon: "brain.head.profile", label: tr("מיינדפולנס", "Mindfulness"),
                              value: tr("\(Int(mindful)) דק'", "\(Int(mindful)) min"), tint: .limorMint))
        }
        return rows
    }

    // MARK: Stats

    private var statsRow: some View {
        let pending = allReminders.filter { $0.status == .pending }
        let overdue = pending.filter { $0.isOverdue }.count
        let todayCount = pending.filter { isToday($0.dueDate) }.count
        let done = allReminders.filter { $0.status == .completed }.count

        return HStack(spacing: 10) {
            StatPill(icon: "exclamationmark.triangle.fill", value: "\(overdue)", label: tr("באיחור", "Overdue"), tint: .limorDanger)
            StatPill(icon: "calendar", value: "\(todayCount)", label: tr("היום", "Today"), tint: .limorIndigo)
            StatPill(icon: "checkmark.circle.fill", value: "\(done)", label: tr("הושלמו", "Done"), tint: .limorSuccess)
        }
    }

    private func isToday(_ d: Date) -> Bool { Calendar.current.isDateInToday(d) }

    // MARK: Loading

    /// "Do EVERYTHING" refresh — used by BOTH the pull-to-refresh gesture and
    /// the toolbar refresh button so they behave identically: calendar, email →
    /// insights/flights/email-actions, health, and a forced news-feed regen,
    /// then re-pull the home snapshot. The held `.fullRefresh` activity keeps
    /// the status chip continuous and settles into one stamped
    /// "רעננתי לך הכל ✨ · היום HH:mm" line instead of whichever sub-step
    /// finished last.
    /// `forced` (manual button / pull-to-refresh) bypasses every throttle +
    /// cooldown — a true "regenerate everything now". The auto path (app entry /
    /// foreground) passes `forced: false`, which respects the per-source
    /// throttles and the feed's 24h cooldown so it doesn't burn the LLM budget,
    /// while still re-pulling snapshots and showing the stamped status line.
    /// The auto path is lightly throttled so a quick app-switch bounce (or the
    /// `.task` + scenePhase both firing on cold launch) doesn't double-run.
    /// Populate the home with sample data for `DemoMode` (no network).
    private func seedDemo() {
        snapshot = DemoData.snapshot
        allReminders = DemoData.reminders
        insights = DemoData.insights
        feed = DemoData.feed
        SharedStore.cacheTasks(DemoData.tasks)
        isLoading = false
    }

    private func fullRefresh(forced: Bool = true) async {
        if DemoMode.isOn { return }
        if !forced {
            guard Date().timeIntervalSince(lastAutoFullRefresh) > 8 else { return }
        }
        lastAutoFullRefresh = Date()
        sync.beginFullRefresh()
        // Global cards (World Cup, war index) regenerate server-side in the
        // background — they run web searches (~30s when stale), so they must
        // not hold up the pull-to-refresh spinner. The cards observe
        // `lastGlobalCardsRefresh` and re-fetch when this lands.
        Task { @MainActor in
            _ = try? await APIClient.shared.refreshWorldCup(force: forced)
            SyncManager.shared.markGlobalCardsRefresh()
        }
        await SyncManager.shared.syncAll(force: forced)
        sync.startActivity(.feed)
        if let fresh = try? await APIClient.shared.refreshFeed(force: forced) {
            feed = fresh
        }
        sync.finishActivity(.feed)
        await reload()
        sync.endFullRefresh()
    }

    private func reload() async {
        if DemoMode.isOn { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let snap = APIClient.shared.now(
                token: auth.token ?? "",
                lat: location.coordinate?.latitude,
                lng: location.coordinate?.longitude
            )
            async let list = APIClient.shared.listReminders(token: auth.token ?? "")
            async let bundle = APIClient.shared.getInsights()
            async let feedSnap = APIClient.shared.getFeed()

            let (s, l, ib, fb) = try await (snap, list, bundle, feedSnap)
            snapshot = s
            allReminders = l
            insights = ib
            feed = fb
            if let data = try? JSONEncoder().encode(s) {
                SharedStore.cacheLastNow(data)
            }
            // Cache the full reminders list + upcoming meetings so
            // the watch's "תזכורות" and "פגישות" tabs aren't limited
            // to the single `next_reminder` packed inside NowResponse.
            // EventKit is iOS-only so the watch can't fetch meetings
            // itself; we stash the rendered DTOs in SharedStore and
            // ride them over WCSession.
            SharedStore.cacheReminders(l)
            let upcomingEvents = CalendarManager.shared
                .fetchUpcomingEvents(daysAhead: 14)
                .prefix(30)
                .map { $0 }
            SharedStore.cacheMeetings(Array(upcomingEvents))
            // Mirror everything to the watch in a single context push.
            WatchSyncManager.shared.pushSnapshot()
            await ActivityController.sync(with: s.next_reminder)
            withAnimation(.spring) { errorMessage = nil }
        } catch {
            withAnimation { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Reminder actions on the hero card

    /// Mark the surfaced reminder complete. Optimistically yanks it from
    /// `allReminders` so the carousel slides to the next pending card
    /// (or collapses to "all clear") without waiting for the network.
    @MainActor
    private func completeNextReminder(_ r: Reminder) async {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.25)) {
            allReminders = allReminders.map { item in
                guard item.id == r.id else { return item }
                return Reminder(
                    id: item.id, task: item.task, due_at: item.due_at,
                    status: .completed, created_at: item.created_at,
                    completed_at: ISO8601DateFormatter.limor.string(from: Date()),
                    msUntilDue: item.msUntilDue, isOverdue: false
                )
            }
            // Don't let the index drift past the new last card.
            let pendingCount = allReminders.filter { $0.status == .pending }.count
            if reminderHeroIndex >= pendingCount { reminderHeroIndex = 0 }
        }
        do {
            _ = try await APIClient.shared.completeReminder(token: auth.token ?? "", id: r.id)
            await RemindersWriter.shared.markCompleted(reminderId: r.id)
            await ActivityController.endAll()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    /// Snooze the surfaced reminder by `minutes`. Stays in the carousel
    /// but re-sorts so it's no longer at the front.
    @MainActor
    private func snoozeNextReminder(_ r: Reminder, minutes: Int) async {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let newDue = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        withAnimation(.easeInOut(duration: 0.25)) {
            allReminders = allReminders.map { item in
                guard item.id == r.id else { return item }
                return Reminder(
                    id: item.id, task: item.task,
                    due_at: ISO8601DateFormatter.limor.string(from: newDue),
                    status: item.status, created_at: item.created_at,
                    completed_at: item.completed_at,
                    msUntilDue: newDue.timeIntervalSinceNow * 1000,
                    isOverdue: false
                )
            }
        }
        do {
            _ = try await APIClient.shared.snoozeReminder(
                token: auth.token ?? "", id: r.id, minutes: minutes
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }
}

private struct HealthStat: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.08))
        )
    }
}

struct HealthDetailRowData: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let value: String
    let tint: Color
}

struct CompactHealthItem: Identifiable {
    let id = UUID()
    let icon: String
    let text: String
    let tint: Color
}

private struct HealthDetailRow: View {
    let row: HealthDetailRowData

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(row.tint.opacity(0.15)).frame(width: 30, height: 30)
                Image(systemName: row.icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(row.tint)
            }
            Text(row.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(row.value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.limorInk)
        }
    }
}

struct LastWorkoutCard: View {
    let workout: WorkoutSummary
    let weekCount: Int?
    let weekMinutes: Double?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LimorGradient.warm)
                .shadow(color: Color.limorCoral.opacity(0.3), radius: 18, y: 10)

            // Decorative circle
            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: 160, height: 160)
                .offset(x: 110, y: -50)
                .blur(radius: 24)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(tr("האימון האחרון", "Last workout"), systemImage: "trophy.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(relativeTime).font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.95))

                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle().fill(.white.opacity(0.25)).frame(width: 56, height: 56)
                        Image(systemName: workout.activity_symbol)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.activity_name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        Text(durationString)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                }

                HStack(spacing: 16) {
                    if let cals = workout.calories_kcal {
                        WorkoutMetric(icon: "flame.fill", value: "\(Int(cals.rounded()))", unit: "kcal")
                    }
                    if let dist = workout.distance_km, dist > 0 {
                        WorkoutMetric(icon: "map.fill", value: String(format: "%.1f", dist), unit: tr("ק\"מ", "km"))
                    }
                    if let hr = workout.avg_heart_rate {
                        WorkoutMetric(icon: "heart.fill", value: "\(hr)", unit: "bpm")
                    }
                    Spacer()
                }

                if let weekCount, weekCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.checkmark")
                        Text(tr("השבוע: \(weekCount) אימונים\(weekMinutes.map { " • \(Int($0)) דק'" } ?? "")", "This week: \(weekCount) workouts\(weekMinutes.map { " • \(Int($0)) min" } ?? "")"))
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(20)
        }
        // Clip the decorative blurred circle (160pt wide, offset +110x/-50y)
        // to the card's rounded rect. Same issue we already fixed on the
        // reminder hero and FlightCard — without clipping, the circle
        // draws past the right edge and NowView's parent ScrollView
        // mistakes it for horizontal content, letting the home screen
        // pan sideways. The card only shows when there's a recent
        // workout in HealthKit, which is why the bug felt intermittent.
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var relativeTime: String {
        guard let date = ISO8601DateFormatter.limor.date(from: workout.start_at) else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var durationString: String {
        let mins = Int(workout.duration_minutes.rounded())
        if mins >= 60 {
            let h = mins / 60, m = mins % 60
            return m == 0 ? tr("\(h) שעות", "\(h) hrs") : tr("\(h)ש' \(m)דק'", "\(h)h \(m)m")
        }
        return tr("\(mins) דקות", "\(mins) min")
    }
}

struct WorkoutMetric: View {
    let icon: String
    let value: String
    let unit: String
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2.weight(.bold))
                Text(value).font(.subheadline.weight(.bold).monospacedDigit())
            }
            Text(unit).font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.18)))
    }
}

import HealthKit
private func HKHealthAvailable() -> Bool {
    HKHealthStore.isHealthDataAvailable()
}

// MARK: - Flight card

private struct FlightCard: View {
    let flight: FlightInsight
    /// Optional dismiss handler — the AI extractor sometimes hallucinates
    /// flights from old emails. Tapping the trash icon hides the card and
    /// records the flight id so it doesn't come back after the next
    /// insights refresh.
    var onDismiss: (() -> Void)? = nil
    /// When the user has multiple upcoming flights queued, the parent
    /// passes (current, total) so we render a page-dot strip *inside* the
    /// card. Placing the dots outside (in a wrapping VStack) caused two
    /// problems: the dots looked detached, and the extra outer layout
    /// re-introduced the home-tab horizontal-pan bug. Inside the
    /// clipShape they can't leak past the card bounds.
    var position: (index: Int, total: Int)? = nil
    var onAdvance: (() -> Void)? = nil
    /// Hotel matched to this flight (same destination + dates, or shared
    /// booking reference). Rendered as a strip under the route; nil when no
    /// stay matched this flight.
    var hotel: HotelInsight? = nil
    @State private var showingDismissConfirm = false

    // Aviation palette — deep ocean → bright teal. Pushed darker on the
    // top-leading and lighter on the bottom-trailing to give the gradient
    // more depth than the previous one had.
    private static let topColor    = Color(red: 0.04, green: 0.20, blue: 0.45)  // deep ocean / night
    private static let bottomColor = Color(red: 0.16, green: 0.62, blue: 0.72)  // teal / surf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topRow
            routeStrip
            metaLine
            if let hotel { hotelStrip(hotel) }
            if let position, position.total > 1 {
                LimorPageDots(
                    count: position.total,
                    index: position.index,
                    activeColor: .white,
                    inactiveColor: .white
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture { onAdvance?() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `.background` instead of a sibling ZStack so the decorative
        // 230×230 / 160×160 glow circles don't dictate card height —
        // they used to push the card to ~230pt minimum, leaving a dead
        // band of gradient below the page dots. With `.background` the
        // backdrop paints into whatever size the content asks for and
        // the inner circles' overflow gets clipped by the outer
        // clipShape on the way out.
        .background { backdrop }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    // MARK: - Background

    private var backdrop: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(
                    colors: [Self.topColor, Self.bottomColor],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .shadow(color: Self.topColor.opacity(0.32), radius: 22, y: 12)

            // Big soft glow in the trailing corner.
            Circle()
                .fill(.white.opacity(0.22))
                .frame(width: 230, height: 230)
                .offset(x: 150, y: -110)
                .blur(radius: 50)
            // A cooler accent glow on the opposite side — gives the card
            // a sense of depth instead of a single light source.
            Circle()
                .fill(Color(red: 0.45, green: 0.90, blue: 1.0).opacity(0.20))
                .frame(width: 160, height: 160)
                .offset(x: -90, y: 140)
                .blur(radius: 40)
        }
    }

    // MARK: - Top row (title + days-away + dismiss)

    private var topRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.white.opacity(0.18)).frame(width: 32, height: 32)
                Image(systemName: "airplane.departure")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("הטיסה הקרובה שלך", "Your upcoming flight"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if let airline = flight.airline {
                    Text(airline)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            Spacer()
            if let days = daysAway {
                Text(daysAwayLabel(days))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.25)))
            }
            if onDismiss != nil {
                Button {
                    showingDismissConfirm = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .confirmationDialog(tr("הטיסה לא נכונה?", "Wrong flight?"), isPresented: $showingDismissConfirm) {
                    Button(tr("מחק את הטיסה הזו", "Delete this flight"), role: .destructive) { onDismiss?() }
                    Button(tr("ביטול", "Cancel"), role: .cancel) {}
                } message: {
                    Text(tr("הטיסה תוסר מהמסך. אם תופיע שוב — סימן שלימור מזהה אותה ממייל; אפשר לדווח לנו.", "The flight will be removed from the screen. If it reappears, Limor is detecting it from an email — feel free to let us know."))
                }
            }
        }
    }

    // MARK: - Route strip (TLV ✈ BKK with dashed connector)

    private var routeStrip: some View {
        HStack(alignment: .center, spacing: 10) {
            // Departure airport — pushed all the way to the leading edge
            // (RTL: right edge of the card) so the route reads from
            // origin to destination with maximum breathing room between.
            airportBlock(
                code: flight.departure_airport ?? "—",
                city: AirportCityLookup.city(for: flight.departure_airport),
                alignment: .leading
            )

            // Animated-feel dashed line with airplane glyph in the
            // middle. Takes whatever space the airport blocks leave.
            connector
                .frame(maxWidth: .infinity)

            airportBlock(
                code: flight.arrival_airport ?? "—",
                city: AirportCityLookup.city(for: flight.arrival_airport),
                alignment: .trailing
            )
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func airportBlock(code: String, city: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(code)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .kerning(1.2)
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            if let city, !city.isEmpty {
                Text(city)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
        }
    }

    private var connector: some View {
        ZStack {
            // Dashed route line behind the plane.
            DashedRouteLine()
                .stroke(
                    Color.white.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
                )
                .frame(height: 1.5)

            // Airplane glyph on a small disc so it sits "above" the line
            // and reads as the centerpiece.
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Self.topColor, Self.bottomColor],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.8))
                Image(systemName: "airplane")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    // In RTL the visual "from → to" goes right-to-left;
                    // SwiftUI auto-mirrors the glyph, but we want the
                    // nose pointing toward destination (left in RTL).
                    // Default symbol points left already; no rotation
                    // needed.
            }
        }
    }

    // MARK: - Meta line (date · time · flight #)

    /// Single-line condensed metadata replacing the previous 3-column
    /// stats strip + chip row. Same info, ~⅓ the vertical real estate.
    /// The full passenger/booking detail is one tap away in
    /// `FlightDetailView`, so the card stays the at-a-glance "what flight
    /// is next" surface.
    private var metaLine: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            metaCell(icon: "calendar", value: dateLabel)
            if hasTimeComponent {
                metaSeparator
                metaCell(icon: "clock.fill", value: timeLabel)
            }
            if let n = flight.flight_number, !n.isEmpty {
                metaSeparator
                metaCell(icon: "number", value: "#\(n)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
    }

    private func metaCell(icon: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.72))
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private var metaSeparator: some View {
        Circle()
            .fill(.white.opacity(0.35))
            .frame(width: 3, height: 3)
    }

    // MARK: - Hotel strip (matched stay)

    private func hotelStrip(_ hotel: HotelInsight) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(.white.opacity(0.18)).frame(width: 26, height: 26)
                Image(systemName: "bed.double.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(hotel.hotel_name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let sub = hotelSubtitle(hotel) {
                    Text(sub)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.8)
        )
    }

    /// "City · 20 Jun–24 Jun" — whichever parts are available.
    private func hotelSubtitle(_ hotel: HotelInsight) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "d MMM"
        var dates: String? = nil
        if let ci = hotel.checkInDate {
            dates = hotel.checkOutDate.map { "\(f.string(from: ci))–\(f.string(from: $0))" } ?? f.string(from: ci)
        }
        let parts = [hotel.city, dates].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private var daysAway: Int? {
        guard let date = flight.departureDate else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        return cal.dateComponents([.day], from: start, to: target).day
    }

    private func daysAwayLabel(_ days: Int) -> String {
        if days == 0 { return tr("היום", "Today") }
        if days == 1 { return tr("מחר", "Tomorrow") }
        if days == 2 { return tr("מחרתיים", "In 2 days") }
        return tr("בעוד \(days) ימים", "In \(days) days")
    }

    private var dateLabel: String {
        guard let date = flight.departureDate else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    private var timeLabel: String {
        guard hasTimeComponent, let date = flight.departureDate else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// True when the source ISO string actually carries a time component.
    /// A bare "YYYY-MM-DD" is exactly 10 chars and contains no "T".
    private var hasTimeComponent: Bool {
        flight.departure_date_iso.contains("T")
    }
}

/// Horizontal dashed line used as the route connector inside FlightCard.
/// A custom Shape lets `.stroke(..., dash:)` actually render — applying a
/// dash pattern to a plain `Rectangle().frame(height:)` collapses to a
/// solid bar.
private struct DashedRouteLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.midY
        p.move(to: CGPoint(x: rect.minX, y: y))
        p.addLine(to: CGPoint(x: rect.maxX, y: y))
        return p
    }
}

/// Minimal IATA-code → Hebrew city-name lookup for the destinations most
/// Israeli travelers actually fly to. Far from exhaustive — we surface
/// the name when known and silently fall back to just the code when not,
/// so an unrecognised airport doesn't look broken.
private enum AirportCityLookup {
    static func city(for code: String?) -> String? {
        guard let code = code?.uppercased(), code.count == 3 else { return nil }
        return mapping[code]
    }

    // Computed (not `let`) so the tr() values re-resolve when the language
    // toggle flips — a stored `static let` would freeze them at first access.
    private static var mapping: [String: String] {
        [
        // Israel
        "TLV": tr("תל אביב", "Tel Aviv"), "ETM": tr("אילת רמון", "Eilat Ramon"), "VDA": tr("עובדה", "Ovda"),
        // Europe
        "LHR": tr("לונדון", "London"), "LGW": tr("לונדון", "London"), "STN": tr("לונדון", "London"), "LTN": tr("לונדון", "London"),
        "CDG": tr("פריז", "Paris"), "ORY": tr("פריז", "Paris"),
        "AMS": tr("אמסטרדם", "Amsterdam"),
        "FRA": tr("פרנקפורט", "Frankfurt"), "MUC": tr("מינכן", "Munich"), "BER": tr("ברלין", "Berlin"),
        "FCO": tr("רומא", "Rome"), "CIA": tr("רומא", "Rome"), "MXP": tr("מילאנו", "Milan"), "LIN": tr("מילאנו", "Milan"),
        "MAD": tr("מדריד", "Madrid"), "BCN": tr("ברצלונה", "Barcelona"),
        "ATH": tr("אתונה", "Athens"), "SKG": tr("סלוניקי", "Thessaloniki"),
        "VIE": tr("וינה", "Vienna"), "ZRH": tr("ציריך", "Zurich"), "GVA": tr("ז׳נבה", "Geneva"),
        "PRG": tr("פראג", "Prague"), "BUD": tr("בודפשט", "Budapest"), "WAW": tr("ורשה", "Warsaw"),
        "CPH": tr("קופנהגן", "Copenhagen"), "ARN": tr("סטוקהולם", "Stockholm"), "HEL": tr("הלסינקי", "Helsinki"), "OSL": tr("אוסלו", "Oslo"),
        "DUB": tr("דבלין", "Dublin"), "LIS": tr("ליסבון", "Lisbon"), "BRU": tr("בריסל", "Brussels"),
        "IST": tr("איסטנבול", "Istanbul"), "SAW": tr("איסטנבול", "Istanbul"),
        "LCA": tr("לרנקה", "Larnaca"), "PFO": tr("פאפוס", "Paphos"),
        "BUH": tr("בוקרשט", "Bucharest"), "OTP": tr("בוקרשט", "Bucharest"), "SOF": tr("סופיה", "Sofia"),
        // Middle East
        "DXB": tr("דובאי", "Dubai"), "AUH": tr("אבו דאבי", "Abu Dhabi"), "DOH": tr("דוחה", "Doha"), "AMM": tr("עמאן", "Amman"),
        "RUH": tr("ריאד", "Riyadh"), "JED": tr("ג׳דה", "Jeddah"),
        // Americas
        "JFK": tr("ניו יורק", "New York"), "LGA": tr("ניו יורק", "New York"), "EWR": tr("ניו יורק / ניוארק", "New York / Newark"),
        "LAX": tr("לוס אנג׳לס", "Los Angeles"), "SFO": tr("סן פרנסיסקו", "San Francisco"),
        "MIA": tr("מיאמי", "Miami"), "ORD": tr("שיקגו", "Chicago"), "BOS": tr("בוסטון", "Boston"),
        "YUL": tr("מונטריאול", "Montreal"), "YYZ": tr("טורונטו", "Toronto"),
        "MEX": tr("מקסיקו סיטי", "Mexico City"),
        // Asia / Pacific
        "BKK": tr("בנגקוק", "Bangkok"), "DMK": tr("בנגקוק", "Bangkok"),
        "HKT": tr("פוקט", "Phuket"), "USM": tr("קוסמוי", "Koh Samui"),
        "SIN": tr("סינגפור", "Singapore"), "KUL": tr("קואלה לומפור", "Kuala Lumpur"),
        "HKG": tr("הונג קונג", "Hong Kong"), "ICN": tr("סיאול", "Seoul"), "NRT": tr("טוקיו", "Tokyo"), "HND": tr("טוקיו", "Tokyo"),
        "DEL": tr("דלהי", "Delhi"), "BOM": tr("מומבאי", "Mumbai"),
        "SYD": tr("סידני", "Sydney"), "MEL": tr("מלבורן", "Melbourne"),
        // Africa
        "JNB": tr("יוהנסבורג", "Johannesburg"), "CPT": tr("קייפטאון", "Cape Town"), "NBO": tr("ניירובי", "Nairobi"), "CAI": tr("קהיר", "Cairo"),
        ]
    }
}

private struct WeatherMinMaxLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.caption.weight(.bold))
            configuration.title.font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(tint)
    }
}

// MARK: - AI Recommendations card

/// Visual style derived from the recommendation kind. Each kind gets a
/// matching SF Symbol and brand-color tint so the card glances readable.
private struct RecKindStyle {
    let icon: String
    let tint: Color
    let label: String

    static func from(_ kind: String) -> RecKindStyle {
        switch kind {
        case "movement":
            return .init(icon: "figure.run", tint: .limorMint, label: tr("תנועה", "Movement"))
        case "sleep":
            return .init(icon: "moon.stars.fill", tint: .limorIndigo, label: tr("שינה", "Sleep"))
        case "recovery":
            return .init(icon: "heart.text.square.fill", tint: .limorViolet, label: tr("התאוששות", "Recovery"))
        case "nutrition":
            return .init(icon: "leaf.fill", tint: .limorMint, label: tr("תזונה", "Nutrition"))
        case "calendar":
            return .init(icon: "calendar.badge.exclamationmark", tint: .limorCoral, label: tr("יומן", "Calendar"))
        case "mindfulness":
            return .init(icon: "brain.head.profile", tint: .limorViolet, label: tr("ראש", "Mind"))
        case "celebration":
            return .init(icon: "trophy.fill", tint: .limorWarning, label: tr("כל הכבוד", "Well done"))
        default:
            return .init(icon: "sparkles", tint: .limorIndigo, label: tr("טיפ", "Tip"))
        }
    }
}

private struct RecommendationsCard: View {
    let recommendations: [Recommendation]
    @State private var index: Int = 0
    @State private var autoAdvanceTask: Task<Void, Never>?
    /// How long each tip stays on screen before auto-rotating. 8 seconds
    /// is long enough to read a 2-3 sentence rec but short enough that
    /// a user passively glancing at the home tab sees a few different
    /// nudges instead of the same one stuck there.
    private let autoAdvanceSeconds: Double = 8

    var body: some View {
        let count = recommendations.count
        VStack(alignment: .trailing, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(LinearGradient(
                        colors: [Color.limorPink, Color.limorViolet, Color.limorIndigo],
                        startPoint: .leading, endPoint: .trailing
                    ))
                Text(tr("טיפ אישי מלימור", "A personal tip from Limor"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                Spacer()
            }

            // Crossfade between recs. Navigation: swipe primary, dots
            // for position + tap-to-advance. The earlier side-chevron
            // version overpowered the card visually; the page pan bug
            // that originally pushed me to chevrons turned out to be
            // unrelated (decorative blurs leaking past card bounds in
            // the reminder hero, now clipped), so swipe is back.
            let current = recommendations.indices.contains(index)
                ? recommendations[index] : recommendations[0]
            RecommendationContent(rec: current)
                .id(current.id)
                .frame(height: cardHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: index)
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            guard count > 1 else { return }
                            let h = value.translation.width
                            let v = value.translation.height
                            guard abs(h) > abs(v), abs(h) > 50 else { return }
                            // RTL: swipe right = next (mirrored from
                            // LTR's "left = next"), swipe left = previous.
                            if h > 0 { advance(by: 1, count: count) }
                            else { advance(by: -1, count: count) }
                            // Manual interaction resets the rotation
                            // clock so the new card gets the full 8s.
                            startAutoAdvance(count: count)
                        }
                )

            if count > 1 {
                LimorPageDots(count: count, index: index)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onTapGesture {
                        advance(by: 1, count: count)
                        startAutoAdvance(count: count)
                    }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassBackground(cornerRadius: 24, tint: nil)
        .overlay(alignment: .topTrailing) {
            // Subtle decorative sparkle
            Image(systemName: "sparkle")
                .font(.caption)
                .foregroundStyle(Color.limorViolet.opacity(0.35))
                .padding(.top, 12).padding(.trailing, 12)
        }
        .onAppear { startAutoAdvance(count: recommendations.count) }
        .onDisappear { autoAdvanceTask?.cancel() }
        .onChange(of: recommendations.count) { _, newCount in
            startAutoAdvance(count: newCount)
        }
    }

    private func advance(by step: Int, count: Int) {
        guard count > 0 else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            index = (index + step + count) % count
        }
    }

    /// Restart the auto-advance loop. Cancels any in-flight task so a
    /// manual swipe/tap doesn't end up racing the timer for control of
    /// `index`. Called from .onAppear, after every manual navigation,
    /// and when the rec count changes.
    private func startAutoAdvance(count: Int) {
        autoAdvanceTask?.cancel()
        guard count > 1 else { return }
        autoAdvanceTask = Task { @MainActor [autoAdvanceSeconds] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(autoAdvanceSeconds))
                if Task.isCancelled { return }
                advance(by: 1, count: count)
            }
        }
    }

    /// Kept only because the project still references the symbol from
    /// other entry points; the tip card itself no longer uses it. Safe
    /// to remove once no other caller depends on it.
    private func chevronButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(LimorGradient.brand)
                        .shadow(color: Color.limorIndigo.opacity(0.35), radius: 6, y: 3)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var cardHeight: CGFloat {
        // Estimate: title (24) + body (44 for ~2 lines) + cta (32) + spacing (16) = ~116
        // Use a stable height so swiping doesn't jump.
        let hasAnyCTA = recommendations.contains { ($0.cta ?? "").isEmpty == false }
        return hasAnyCTA ? 130 : 100
    }
}

private struct RecommendationContent: View {
    let rec: Recommendation
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        let style = RecKindStyle.from(rec.kind)
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(style.tint.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: style.icon)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(style.tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(rec.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                    .lineLimit(1)

                Text(rec.body)
                    .font(.subheadline)
                    .foregroundStyle(.limorInk.opacity(0.78))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let cta = rec.cta, !cta.isEmpty {
                    Button {
                        // Hand the request off to Limor in chat. The CTA on
                        // its own is often ambiguous ("תזכירי לי ב-14:00" —
                        // about WHAT?), so we prepend the recommendation's
                        // title so Limor knows the subject.
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        router.sendToLimor(tr("\(cta) — בקשר ל'\(rec.title)' (\(rec.body))", "\(cta) — regarding '\(rec.title)' (\(rec.body))"))
                    } label: {
                        HStack(spacing: 4) {
                            Text(cta)
                                .font(.caption.weight(.semibold))
                            Image(systemName: "arrow.left")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(style.tint)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(style.tint.opacity(0.14)))
                        .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Flight detail sheet

/// Tap-through from the home-screen flight card. Shows the LLM-extracted
/// fields nicely laid out, plus the original Gmail booking email behind
/// them (subject + body) so the user can verify what Limor extracted.
struct FlightDetailView: View {
    let flight: FlightInsight
    /// Hotel matched to this flight, shown as its own section. nil if none.
    var hotel: HotelInsight? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var email: EmailDTO?
    @State private var loadingEmail = true
    @State private var emailError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    routeHero
                    extractedFieldsCard
                    if let hotel { hotelCard(hotel) }
                    sourceEmailCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .navigationTitle(tr("פרטי טיסה", "Flight details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(tr("סגור", "Close")) { dismiss() }
                        .foregroundStyle(.limorIndigo)
                }
            }
        }
        .task { await loadEmail() }
    }

    // MARK: Route hero

    private var routeHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.36, blue: 0.55),
                        Color(red: 0.20, green: 0.66, blue: 0.62),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .shadow(color: Color(red: 0.07, green: 0.36, blue: 0.55).opacity(0.25), radius: 16, y: 8)

            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(spacing: 4) {
                        Text(flight.departure_airport ?? "—")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(tr("יציאה", "Departure"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Image(systemName: "airplane")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.85))
                    VStack(spacing: 4) {
                        Text(flight.arrival_airport ?? "—")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(tr("יעד", "Destination"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                if let date = flight.departureDate {
                    Text(formattedDateLong(date))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Extracted fields

    private var extractedFieldsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(icon: "list.bullet.rectangle", title: tr("מה לימור חילצה", "What Limor extracted"))
                detailRow(icon: "building.2", label: tr("חברת תעופה", "Airline"), value: flight.airline)
                detailRow(icon: "number", label: tr("מספר טיסה", "Flight number"), value: flight.flight_number)
                detailRow(icon: "person.fill", label: tr("נוסע", "Passenger"), value: flight.passenger_name)
                detailRow(icon: "ticket", label: tr("מספר הזמנה", "Booking reference"), value: flight.booking_reference)
                detailRow(icon: "airplane.departure", label: tr("שדה יציאה", "Departure airport"), value: flight.departure_airport)
                detailRow(icon: "airplane.arrival", label: tr("שדה יעד", "Arrival airport"), value: flight.arrival_airport)
                if let d = flight.departureDate {
                    detailRow(icon: "calendar", label: tr("המראה", "Takeoff"), value: formattedDateLong(d))
                }
            }
        }
    }

    // MARK: Matched hotel

    @ViewBuilder
    private func hotelCard(_ hotel: HotelInsight) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(icon: "bed.double.fill", title: tr("המלון לטיסה הזו", "Hotel for this flight"))
                detailRow(icon: "building", label: tr("מלון", "Hotel"), value: hotel.hotel_name)
                detailRow(icon: "mappin.and.ellipse", label: tr("עיר", "City"), value: hotel.city)
                detailRow(icon: "location", label: tr("כתובת", "Address"), value: hotel.address)
                if let ci = hotel.checkInDate {
                    detailRow(icon: "calendar.badge.plus", label: tr("צ'ק-אין", "Check-in"), value: formattedDateLong(ci))
                }
                if let co = hotel.checkOutDate {
                    detailRow(icon: "calendar.badge.minus", label: tr("צ'ק-אאוט", "Check-out"), value: formattedDateLong(co))
                }
                detailRow(icon: "person.fill", label: tr("אורח", "Guest"), value: hotel.guest_name)
                detailRow(icon: "ticket", label: tr("מספר הזמנה", "Booking reference"), value: hotel.booking_reference)
            }
        }
    }

    @ViewBuilder
    private func detailRow(icon: String, label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.limorIndigo)
                    .frame(width: 18)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
                Spacer(minLength: 8)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: Source email

    @ViewBuilder
    private var sourceEmailCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(icon: "envelope", title: tr("המייל המקורי", "Original email"))
                if loadingEmail {
                    HStack(spacing: 8) {
                        ProgressView().tint(.limorIndigo)
                        Text(tr("טוען את המייל…", "Loading email…"))
                            .font(.subheadline)
                            .foregroundStyle(.limorMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let email {
                    emailContent(email)
                } else if let err = emailError {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                } else {
                    Text(tr("המייל המקורי כבר לא מסונכרן (יוצא מהרשימה אחרי שעבר מספיק זמן).", "The original email is no longer synced (it drops off the list after enough time passes)."))
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                }
            }
        }
    }

    private func emailContent(_ email: EmailDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("נושא", "Subject"))
                    .font(.caption).foregroundStyle(.limorMuted)
                Text(email.subject.isEmpty ? "—" : email.subject)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("מאת", "From"))
                    .font(.caption).foregroundStyle(.limorMuted)
                Text(email.from_name?.isEmpty == false ? "\(email.from_name!) <\(email.from)>" : email.from)
                    .font(.subheadline)
                    .foregroundStyle(.limorInk)
                    .textSelection(.enabled)
            }
            if let date = parseEmailDate(email.received_at) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("התקבל", "Received"))
                        .font(.caption).foregroundStyle(.limorMuted)
                    Text(formattedDateLong(date))
                        .font(.subheadline)
                        .foregroundStyle(.limorInk)
                }
            }
            Divider().padding(.vertical, 4)
            let body = (email.body_text?.isEmpty == false ? email.body_text! : email.snippet)
            if !body.isEmpty {
                Text(body)
                    .font(.body)
                    .foregroundStyle(.limorInk.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(tr("גוף המייל לא נשמר.", "The email body wasn't saved."))
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
            }
        }
    }

    // MARK: Helpers

    private func loadEmail() async {
        guard let id = flight.source_email_id, !id.isEmpty else {
            loadingEmail = false
            return
        }
        do {
            email = try await APIClient.shared.emailById(messageId: id)
        } catch {
            emailError = tr("טעינת המייל נכשלה: \(error.localizedDescription)", "Failed to load the email: \(error.localizedDescription)")
        }
        loadingEmail = false
    }

    private func formattedDateLong(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = flight.departure_date_iso.contains("T")
            ? "EEEE d MMMM y, HH:mm"
            : "EEEE d MMMM y"
        return f.string(from: date)
    }

    private func parseEmailDate(_ iso: String) -> Date? {
        if let d = ISO8601DateFormatter.limor.date(from: iso) { return d }
        return ISO8601DateFormatter().date(from: iso)
    }
}

// MARK: - Drag-to-reorder home cards

/// Live reorder of the home cards as you long-press and drag one over another.
struct CardReorderDrop: DropDelegate {
    let target: HomeCardKind
    @Binding var order: [HomeCardKind]
    @Binding var dragged: HomeCardKind?
    let onCommit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }
        if order[to] != dragged {
            withAnimation(.easeInOut(duration: 0.2)) {
                order.move(fromOffsets: IndexSet(integer: from),
                           toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        onCommit()
        return true
    }
}

// MARK: - Masonry layout (gap-free multi-column packing)

/// Places each subview into the currently-shortest column — a true masonry
/// (Pinterest-style) pack, so short and tall cards interleave with no gaps.
/// Subview order = `cardOrder`, so drag-reorder rearranges the flow while it
/// stays packed.
struct MasonryLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    private func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        let cols = max(1, columns)
        return (totalWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let total = proposal.width ?? 0
        let colW = columnWidth(for: total)
        var heights = Array(repeating: CGFloat(0), count: max(1, columns))
        for sv in subviews {
            let h = sv.sizeThatFits(.init(width: colW, height: nil)).height
            let c = shortest(heights)
            heights[c] += h + spacing
        }
        let tallest = heights.max() ?? 0
        return CGSize(width: total, height: max(0, tallest - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let colW = columnWidth(for: bounds.width)
        var heights = Array(repeating: CGFloat(0), count: max(1, columns))
        for sv in subviews {
            let h = sv.sizeThatFits(.init(width: colW, height: nil)).height
            let c = shortest(heights)
            let x = bounds.minX + CGFloat(c) * (colW + spacing)
            let y = bounds.minY + heights[c]
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                     proposal: .init(width: colW, height: h))
            heights[c] += h + spacing
        }
    }

    private func shortest(_ heights: [CGFloat]) -> Int {
        var idx = 0
        for i in heights.indices where heights[i] < heights[idx] { idx = i }
        return idx
    }
}
