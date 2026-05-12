import SwiftUI

struct NowView: View {
    @EnvironmentObject private var auth: AuthManager
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

    private var tod: LimorTimeOfDay { .current }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        greetingHeader
                        ForEach(cardOrder.filter { !hiddenCards.contains($0) }) { card in
                            cardView(for: card)
                        }

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
                            Task { await reload() }
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
            .refreshable {
                // Pull-to-refresh forces a fresh sync (Gmail + insights too) so
                // newly-arrived emails show up as flight cards immediately.
                await SyncManager.shared.syncAll(force: true)
                await reload()
            }
            .onChange(of: sync.lastInsightsRefresh) { _, _ in
                // Backend just finished extracting insights — pull the new
                // snapshot so the flight card appears without a tab switch.
                Task { await reload() }
            }
            .task {
                // Show last cached snapshot immediately so the screen isn't blank
                // while we hit the network.
                if snapshot == nil, let cached = SharedStore.loadLastNow() {
                    snapshot = cached
                }
                location.requestWhenInUseAndStart()
                _ = await health.requestAccess()
                await health.loadToday()
                Task { await SyncManager.shared.syncHealth() }
                await reload()
            }
            .onChange(of: location.coordinate?.latitude) { _, _ in
                Task { await reload() }
            }
        }
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

            Text(name?.isEmpty == false ? name! : "שלום")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.black)
        }
    }

    // MARK: Card dispatch (drives user-customizable order)

    @ViewBuilder
    private func cardView(for card: HomeCardKind) -> some View {
        switch card {
        case .nextReminder:    nextReminderHero
        case .recommendations: recommendationsCard
        case .meetings:        MeetingsCard()
        case .feed:            feedCard
        case .nextFlight:      nextFlightCard
        case .weather:         weatherCard
        case .shopping:        ShoppingListCard()
        case .health:          healthCard
        case .stats:           statsRow
        }
    }

    // MARK: Hero — next reminder

    private var nextReminderHero: some View {
        Group {
            if let r = snapshot?.next_reminder {
                // Once a reminder is past its due time, swap the whole
                // hero's color scheme to the danger gradient so it
                // reads as "needs attention" at a glance — purple with
                // a small red pill wasn't loud enough.
                let overdue = r.isOverdue
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(overdue ? LimorGradient.danger : LimorGradient.brand)
                        .shadow(
                            color: (overdue ? Color.limorDanger : Color.limorIndigo).opacity(0.35),
                            radius: 24, y: 14
                        )

                    // Decorative blurred shapes — mirror the dominant
                    // tint so the highlights don't fight the base
                    // gradient when we swap palettes.
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

                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: overdue ? "exclamationmark.triangle.fill" : "bell.fill")
                                .font(.subheadline.weight(.bold))
                            Text(overdue ? "תזכורת באיחור" : "התזכורת הבאה")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if overdue {
                                // High-contrast white pill on the red card —
                                // a red-on-red pill would disappear into
                                // the background.
                                Text("באיחור")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.limorDanger)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(.white))
                            }
                        }
                        .foregroundStyle(.white.opacity(0.95))

                        Text(r.task)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(3)

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "clock.fill").font(.title3)
                            Text(r.dueDate, style: .relative)
                                .font(.title3.weight(.bold).monospacedDigit())
                            Text("•").foregroundStyle(.white.opacity(0.4))
                            Text(r.dueDate, style: .time)
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 180)
                .animation(.easeInOut(duration: 0.25), value: overdue)
            } else if isLoading && snapshot == nil {
                // Only show the loading skeleton on the very first load, when we
                // have nothing to show yet. Once we have a snapshot, refreshes
                // keep the "all quiet" / reminder card in place so the layout
                // doesn't jump on every silent re-fetch.
                GlassCard {
                    HStack { ProgressView().tint(.limorIndigo); Text("טוען…").foregroundStyle(.secondary) }
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LimorGradient.mint.opacity(0.85))
                        .shadow(color: Color.limorMint.opacity(0.3), radius: 20, y: 10)
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 38))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("הכל רגוע 🌿").font(.title3.weight(.bold))
                            Text("אין תזכורות פעילות").font(.subheadline)
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
                    SectionLabel(icon: "thermometer.medium", title: "מזג אוויר עכשיו")
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
                            Text(w.condition)
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
                        Text("אישור מיקום נדרש בהגדרות → לימור")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().tint(.limorIndigo)
                        Text("מאתר מיקום…").font(.subheadline).foregroundStyle(.secondary)
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

    // MARK: Next flight (auto-detected from Gmail)

    @ViewBuilder
    private var nextFlightCard: some View {
        if let flight = upcomingFlight {
            FlightCard(flight: flight) {
                // User-triggered dismissal — the AI extractor sometimes
                // hallucinates flights from old/ambiguous emails. Remember
                // the ID so we don't re-show it after the next insights
                // refresh.
                var ids = SharedStore.dismissedFlightIds
                ids.insert(flight.id)
                SharedStore.dismissedFlightIds = ids
                Task { await reload() }
            }
        }
    }

    private var upcomingFlight: FlightInsight? {
        guard let flights = insights?.flights else { return nil }
        let now = Date()
        let dismissed = SharedStore.dismissedFlightIds
        return flights
            .filter { !dismissed.contains($0.id) }
            .filter { ($0.departureDate ?? .distantPast) > now.addingTimeInterval(-3600) }
            .sorted { ($0.departureDate ?? .distantPast) < ($1.departureDate ?? .distantPast) }
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
                                SectionLabel(icon: "heart.fill", title: "בריאות היום")
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
                                        HealthStat(icon: "figure.walk", value: stepsString(steps), label: "צעדים", tint: .limorMint)
                                    }
                                    if let cals = h.active_calories_kcal, cals > 0 {
                                        HealthStat(icon: "flame.fill", value: "\(Int(cals.rounded()))", label: "kcal", tint: .limorCoral)
                                    }
                                    if let mins = h.exercise_minutes, mins > 0 {
                                        HealthStat(icon: "stopwatch.fill", value: "\(mins)", label: "דק' פעילות", tint: .limorViolet)
                                    }
                                    if let stand = h.stand_hours, stand > 0 {
                                        HealthStat(icon: "figure.stand", value: "\(stand)", label: "ש' עמידה", tint: .limorIndigo)
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
                                Text("הצג עוד")
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
                        Text("חבר את Apple Health").font(.subheadline.weight(.semibold))
                        Text("ראי צעדים, קלוריות ועוד").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task {
                            _ = await health.requestAccess()
                            await health.loadToday()
                        }
                    } label: {
                        Text("הפעל")
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
            items.append(.init(icon: "map.fill", text: String(format: "%.1f ק\"מ", dist), tint: .limorIndigo))
        }
        return Array(items.prefix(3))
    }

    private func healthDetailRows(_ h: HealthSummary) -> [HealthDetailRowData] {
        var rows: [HealthDetailRowData] = []
        if let sleep = h.sleep_hours, sleep > 0 {
            rows.append(.init(icon: "moon.zzz.fill", label: "שינה אתמול",
                              value: String(format: "%.1f שעות", sleep), tint: .limorViolet))
        }
        if let rhr = h.resting_heart_rate {
            rows.append(.init(icon: "heart.fill", label: "דופק במנוחה",
                              value: "\(rhr) bpm", tint: .limorCoral))
        }
        if let walking = h.walking_heart_rate_avg {
            rows.append(.init(icon: "figure.walk.motion", label: "דופק בהליכה",
                              value: "\(walking) bpm", tint: .limorCoral))
        }
        if let hrv = h.heart_rate_variability_ms {
            rows.append(.init(icon: "waveform.path.ecg", label: "HRV",
                              value: String(format: "%.0f ms", hrv), tint: .limorCoral))
        }
        if let dist = h.distance_km, dist > 0 {
            rows.append(.init(icon: "map.fill", label: "מרחק",
                              value: String(format: "%.2f ק\"מ", dist), tint: .limorIndigo))
        }
        if let vo2 = h.vo2_max {
            rows.append(.init(icon: "lungs.fill", label: "VO2 Max",
                              value: String(format: "%.1f", vo2), tint: .limorMint))
        }
        if let weight = h.weight_kg {
            rows.append(.init(icon: "scalemass.fill", label: "משקל",
                              value: String(format: "%.1f ק\"ג", weight), tint: .limorIndigo))
        }
        if let bf = h.body_fat_percent, bf > 0 {
            rows.append(.init(icon: "drop.fill", label: "אחוז שומן",
                              value: String(format: "%.1f%%", bf), tint: .limorViolet))
        }
        if let mindful = h.mindful_minutes, mindful > 0 {
            rows.append(.init(icon: "brain.head.profile", label: "מיינדפולנס",
                              value: "\(Int(mindful)) דק'", tint: .limorMint))
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
            StatPill(icon: "exclamationmark.triangle.fill", value: "\(overdue)", label: "באיחור", tint: .limorDanger)
            StatPill(icon: "calendar", value: "\(todayCount)", label: "היום", tint: .limorIndigo)
            StatPill(icon: "checkmark.circle.fill", value: "\(done)", label: "הושלמו", tint: .limorSuccess)
        }
    }

    private func isToday(_ d: Date) -> Bool { Calendar.current.isDateInToday(d) }

    // MARK: Loading

    private func reload() async {
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
            await ActivityController.sync(with: s.next_reminder)
            withAnimation(.spring) { errorMessage = nil }
        } catch {
            withAnimation { errorMessage = error.localizedDescription }
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
                    Label("האימון האחרון", systemImage: "trophy.fill")
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
                        WorkoutMetric(icon: "map.fill", value: String(format: "%.1f", dist), unit: "ק\"מ")
                    }
                    if let hr = workout.avg_heart_rate {
                        WorkoutMetric(icon: "heart.fill", value: "\(hr)", unit: "bpm")
                    }
                    Spacer()
                }

                if let weekCount, weekCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.checkmark")
                        Text("השבוע: \(weekCount) אימונים\(weekMinutes.map { " • \(Int($0)) דק'" } ?? "")")
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(20)
        }
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
            return m == 0 ? "\(h) שעות" : "\(h)ש' \(m)דק'"
        }
        return "\(mins) דקות"
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
    @State private var showingDismissConfirm = false

    // Aviation palette — deep ocean → teal. Visually distinct from the
    // brand-purple reminder card so the two don't blend on the home screen.
    private static let topColor    = Color(red: 0.07, green: 0.36, blue: 0.55)  // deep ocean
    private static let bottomColor = Color(red: 0.20, green: 0.66, blue: 0.62)  // teal

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(
                    colors: [Self.topColor, Self.bottomColor],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .shadow(color: Self.topColor.opacity(0.30), radius: 20, y: 10)

            // Decorative blurred circles
            Circle()
                .fill(.white.opacity(0.20))
                .frame(width: 200, height: 200)
                .offset(x: 130, y: -90)
                .blur(radius: 40)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "airplane.departure").font(.subheadline.weight(.bold))
                    Text("הטיסה הקרובה שלך").font(.subheadline.weight(.semibold))
                    Spacer()
                    if let days = daysAway {
                        Text(days == 0 ? "היום" : "בעוד \(days) ימים")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.22)))
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
                        .confirmationDialog("הטיסה לא נכונה?", isPresented: $showingDismissConfirm) {
                            Button("מחק את הטיסה הזו", role: .destructive) { onDismiss?() }
                            Button("ביטול", role: .cancel) {}
                        } message: {
                            Text("הטיסה תוסר מהמסך. אם תופיע שוב — סימן שלימור מזהה אותה ממייל; אפשר לדווח לנו.")
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.95))

                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flight.departure_airport ?? "—")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("יציאה").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Image(systemName: "airplane")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .rotationEffect(.degrees(0))
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(flight.arrival_airport ?? "—")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("יעד").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                }

                // Two-row layout — cramming date + airline + flight number
                // on one line was truncating the departure time ("09:30 →
                // 09,...") on smaller widths. Date+time stays prominent on
                // its own row, airline + #number ride below.
                VStack(alignment: .leading, spacing: 6) {
                    if let date = flight.departureDate {
                        Label(formatDate(date), systemImage: "calendar")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    HStack(spacing: 10) {
                        if let airline = flight.airline {
                            Label(airline, systemImage: "building.2")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if let fno = flight.flight_number {
                            Text("#\(fno)").font(.caption.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(.white.opacity(0.18)))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))

                if let ref = flight.booking_reference {
                    HStack(spacing: 6) {
                        Image(systemName: "ticket")
                        Text(ref).monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var daysAway: Int? {
        guard let date = flight.departureDate else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let target = cal.startOfDay(for: date)
        return cal.dateComponents([.day], from: start, to: target).day
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        // Drop the time portion when the backend gave us only a date — better
        // to show "שבת 20 יוני" than to invent a misleading "00:00".
        f.dateFormat = hasTimeComponent ? "EEEE d MMM, HH:mm" : "EEEE d MMM"
        return f.string(from: date)
    }

    /// True when the source ISO string actually carries a time component.
    /// A bare "YYYY-MM-DD" is exactly 10 chars and contains no "T".
    private var hasTimeComponent: Bool {
        flight.departure_date_iso.contains("T")
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
            return .init(icon: "figure.run", tint: .limorMint, label: "תנועה")
        case "sleep":
            return .init(icon: "moon.stars.fill", tint: .limorIndigo, label: "שינה")
        case "recovery":
            return .init(icon: "heart.text.square.fill", tint: .limorViolet, label: "התאוששות")
        case "nutrition":
            return .init(icon: "leaf.fill", tint: .limorMint, label: "תזונה")
        case "calendar":
            return .init(icon: "calendar.badge.exclamationmark", tint: .limorCoral, label: "יומן")
        case "mindfulness":
            return .init(icon: "brain.head.profile", tint: .limorViolet, label: "ראש")
        case "celebration":
            return .init(icon: "trophy.fill", tint: .limorWarning, label: "כל הכבוד")
        default:
            return .init(icon: "sparkles", tint: .limorIndigo, label: "טיפ")
        }
    }
}

private struct RecommendationsCard: View {
    let recommendations: [Recommendation]
    @State private var index: Int = 0

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
                Text("טיפ אישי מלימור")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                Spacer()
            }

            // Swipeable carousel when there are multiple recs.
            // No layoutDirection override here — let SwiftUI keep RTL so the
            // icon sits on the right, matching the rest of the Hebrew UI.
            TabView(selection: $index) {
                ForEach(Array(recommendations.enumerated()), id: \.element.id) { i, rec in
                    RecommendationContent(rec: rec)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: cardHeight)
            .animation(.easeInOut(duration: 0.35), value: index)

            if count > 1 {
                LimorPageControls(
                    count: count,
                    index: index,
                    onBack: { advance(by: -1, count: count) },
                    onForward: { advance(by: 1, count: count) }
                )
                .frame(maxWidth: .infinity, alignment: .center)
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
    }

    private func advance(by step: Int, count: Int) {
        guard count > 0 else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            index = (index + step + count) % count
        }
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
                        router.sendToLimor("\(cta) — בקשר ל'\(rec.title)' (\(rec.body))")
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
