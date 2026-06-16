import Foundation

/// Coordinates background sync of calendar events and contacts to the backend.
/// Throttles each kind to once per hour to avoid hammering Firestore + the
/// EventKit/Contacts indexers.
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published private(set) var lastCalendarSync: Date?
    @Published private(set) var lastContactsSync: Date?
    @Published private(set) var lastHealthSync: Date?
    @Published private(set) var lastEmailSync: Date?
    /// Updated only after `/api/insights/refresh` returns. Views can observe
    /// this to know when the insights snapshot is actually fresh on the server.
    @Published private(set) var lastInsightsRefresh: Date?
    /// Updated after `/api/email/actions/refresh` returns (server-side 24h
    /// cooldown). The executive email report card observes this to re-fetch.
    @Published private(set) var lastEmailActionsRefresh: Date?
    /// Bumped after the GLOBAL card bundles (World Cup, war index) were
    /// refreshed server-side by a home full-refresh. The cards observe this
    /// and re-fetch — their state lives inside the card views, not NowView.
    @Published private(set) var lastGlobalCardsRefresh: Date?
    func markGlobalCardsRefresh() { lastGlobalCardsRefresh = Date() }
    @Published private(set) var isSyncing = false

    // MARK: - Background activity status (home-screen "Limor is working" chip)

    /// A discrete thing Limor is doing in the background. The home screen
    /// surfaces a friendly label so the user knows work is happening (e.g.
    /// "מחפשת טיסות") instead of waiting on a card that silently appears.
    enum LimorActivity: String, CaseIterable, Hashable {
        case email, insights, emailActions, feed, calendar, fullRefresh

        /// Present-tense label shown while the activity runs ("לימור …").
        var working: String {
            switch self {
            case .email:        return tr("סורקת את המייל שלך", "Scanning your email")
            case .insights:     return tr("מחפשת טיסות ותובנות", "Looking for flights and insights")
            case .emailActions: return tr("עוברת על המשימות מהמייל", "Reviewing tasks from your email")
            case .feed:         return tr("מעדכנת לך חדשות", "Updating your news")
            case .calendar:     return tr("מסנכרנת את היומן", "Syncing your calendar")
            case .fullRefresh:  return tr("מרעננת לך הכל", "Refreshing everything")
            }
        }

        /// Lower = higher priority when choosing which label to headline.
        /// `.fullRefresh` is lowest so the specific sub-step label shows while
        /// it runs, and "מרעננת לך הכל" only appears in the gaps.
        var order: Int {
            switch self {
            case .email:        return 0
            case .insights:     return 1
            case .emailActions: return 2
            case .feed:         return 3
            case .calendar:     return 4
            case .fullRefresh:  return 99
            }
        }
    }

    /// True while an explicit pull-to-refresh "do everything" batch is running.
    /// When the batch ends, the done line becomes one consolidated, timestamped
    /// message instead of whichever sub-step happened to finish last.
    private var fullRefreshActive = false

    /// Start a full refresh: hold a `.fullRefresh` activity so the chip stays
    /// visible continuously (no premature "done" in the gaps between steps).
    func beginFullRefresh() {
        fullRefreshActive = true
        beginActivity(.fullRefresh)
    }

    /// End a full refresh — releases the held activity, which (once the real
    /// sub-steps are also done) settles into the consolidated done line.
    func endFullRefresh() {
        endActivity(.fullRefresh)
    }

    private func timestampNow() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "HH:mm"
        return tr("היום \(f.string(from: Date()))", "Today \(f.string(from: Date()))")
    }

    /// What the home-screen chip shows. A SINGLE source of truth so the chip
    /// never collapses to nothing between two activities (which made the line
    /// flicker — disappear and jump back). It stays `.working` continuously
    /// while anything runs, and the `.done` line persists until the next batch.
    enum ChipState: Equatable {
        case idle
        case working(String)
        case done(String)
    }
    @Published private(set) var chipState: ChipState = .idle

    /// Currently-running background activities (drives the working headline).
    private var activities: Set<LimorActivity> = []
    /// Activities seen since the chip was last idle — composes the done line.
    private var ranThisBatch: Set<LimorActivity> = []
    /// Debounced finalize: only flip to `.done` once nothing has run for a
    /// short window, so the gaps between sequential syncAll steps (calendar →
    /// contacts/health → email) keep the chip on its last `.working` label
    /// instead of blanking and jumping.
    private var finalizeTask: Task<Void, Never>?

    /// The most relevant in-progress label, or nil when nothing runs.
    private var activityHeadline: String? {
        activities.sorted { $0.order < $1.order }.first?.working
    }

    /// Begin tracking a background activity. Public so view-side work that
    /// isn't routed through SyncManager (e.g. the home feed regen) can light
    /// up the same chip. Idempotent.
    func startActivity(_ a: LimorActivity) { beginActivity(a) }
    /// Finish tracking a background activity. Pair with `startActivity`.
    func finishActivity(_ a: LimorActivity) { endActivity(a) }

    private func beginActivity(_ a: LimorActivity) {
        finalizeTask?.cancel()
        finalizeTask = nil
        ranThisBatch.insert(a)
        activities.insert(a)
        if let h = activityHeadline { chipState = .working(h) }
    }

    private func endActivity(_ a: LimorActivity) {
        activities.remove(a)
        if let h = activityHeadline {
            // Something else is still running — swap the label in place.
            chipState = .working(h)
        } else {
            // Nothing running. DON'T blank the chip — keep showing the last
            // `.working` label and only settle into `.done` if the lull holds.
            scheduleFinalize()
        }
    }

    private func scheduleFinalize() {
        finalizeTask?.cancel()
        let batch = ranThisBatch
        finalizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled, self.activities.isEmpty else { return }
            self.chipState = .done(self.doneMessage(for: batch))
            self.ranThisBatch.removeAll()
        }
    }

    private func doneMessage(for ran: Set<LimorActivity>) -> String {
        // Explicit pull-to-refresh ran everything → one consolidated, stamped
        // line (instead of whichever sub-step finished last).
        if fullRefreshActive {
            fullRefreshActive = false
            return tr("רעננתי לך הכל ✨ · \(timestampNow())", "Refreshed everything for you ✨ · \(timestampNow())")
        }
        // The email report runs only on an explicit refresh — name it exactly.
        if ran.contains(.emailActions) {
            return tr("עדכנתי לך את מוקד המייל ✨", "Updated your email focus ✨")
        }
        // Insights = the AI scan that pulls flights / hotels / expenses + tip.
        if ran.contains(.insights) {
            return tr("עברתי על המייל ועדכנתי תובנות (טיסות, הוצאות) ✨", "Went through your email and updated insights (flights, expenses) ✨")
        }
        if ran.contains(.email) {
            return tr("סנכרנתי לך את המייל ✨", "Synced your email ✨")
        }
        if ran.contains(.feed) {
            return tr("עדכנתי לך את החדשות ✨", "Updated your news ✨")
        }
        if ran.contains(.calendar) {
            return tr("סנכרנתי את היומן ✨", "Synced your calendar ✨")
        }
        return tr("הכול מעודכן ✨", "Everything's up to date ✨")
    }

    /// Per-type throttle. Email/insights are the most "fresh data" sensitive,
    /// so they re-run more frequently. Contacts barely change → longer.
    private let emailThrottle: TimeInterval = 15 * 60   // 15 minutes
    private let calendarThrottle: TimeInterval = 30 * 60
    private let healthThrottle: TimeInterval = 30 * 60
    private let contactsThrottle: TimeInterval = 6 * 60 * 60   // 6 hours
    private let throttleSeconds: TimeInterval = 30 * 60        // legacy default

    func syncCalendar(force: Bool = false) async {
        if !force, let last = lastCalendarSync, Date().timeIntervalSince(last) < calendarThrottle { return }

        let sources = SharedStore.calendarSources
        guard !sources.isEmpty else {
            print("[sync] calendar: no sources enabled, skipping")
            return
        }

        beginActivity(.calendar)
        defer { endActivity(.calendar) }

        // Fetch from each enabled source; a single provider's failure must not
        // wipe out the others' results (otherwise a transient Google outage
        // would clear the user's Outlook events from the backend snapshot).
        var events: [CalendarEventDTO] = []

        if sources.contains(.apple) {
            let granted = await CalendarManager.shared.requestAccess()
            if granted {
                events.append(contentsOf: CalendarManager.shared.fetchUpcomingEvents())
            }
        }
        if sources.contains(.google) {
            do {
                events.append(contentsOf: try await GoogleAPIs.fetchCalendarEvents())
            } catch {
                print("[sync] google calendar failed: \(error.localizedDescription)")
            }
        }
        if sources.contains(.microsoft) {
            do {
                events.append(contentsOf: try await MicrosoftAPIs.fetchCalendarEvents())
            } catch {
                print("[sync] microsoft calendar failed: \(error.localizedDescription)")
            }
        }

        do {
            try await APIClient.shared.syncCalendar(events: events)
            lastCalendarSync = Date()
            let names = sources.map(\.rawValue).sorted().joined(separator: "+")
            print("[sync] calendar (\(names)) uploaded \(events.count) events")
        } catch {
            print("[sync] calendar upload failed: \(error.localizedDescription)")
        }
    }

    /// Stamp a fetched email with which account it came from, so the backend
    /// action extractor can attribute each item back to a Gmail/Outlook account.
    private func tag(_ email: EmailDTO, provider: String, account: String?) -> EmailDTO {
        var e = email
        e.provider = provider
        e.account_email = account
        return e
    }

    func syncEmail(force: Bool = false) async {
        let sources = SharedStore.emailSources
        guard !sources.isEmpty else {
            print("[sync] email: no sources enabled, skipping")
            return
        }
        if !force, let last = lastEmailSync, Date().timeIntervalSince(last) < emailThrottle {
            print("[sync] email: throttled (last=\(last))")
            return
        }
        beginActivity(.email)
        do {
            // Fetch from each enabled provider in parallel — keeps total wait
            // bounded by the slower one, not the sum. Failures are logged and
            // the other provider's results still upload (same reasoning as
            // calendar: a transient Gmail error must not wipe Outlook data).
            var emails: [EmailDTO] = []
            if sources.contains(.google) {
                let granted = GoogleAPIs.grantedScopes()
                print("[sync] email: starting Gmail fetch. Granted Google scopes: \(granted)")
                do {
                    let acct = GoogleAPIs.accountEmail()
                    let batch = try await GoogleAPIs.fetchRecentEmails(daysBack: 14, limit: 300)
                        .map { tag($0, provider: "google", account: acct) }
                    emails.append(contentsOf: batch)
                } catch {
                    print("[sync] gmail fetch failed: \(error.localizedDescription)")
                }
            }
            if sources.contains(.microsoft) {
                let granted = MicrosoftAPIs.grantedScopes()
                print("[sync] email: starting Outlook fetch. Granted MS scopes: \(granted)")
                do {
                    let acct = MicrosoftAPIs.accountEmail()
                    let batch = try await MicrosoftAPIs.fetchRecentEmails(daysBack: 14, limit: 300)
                        .map { tag($0, provider: "microsoft", account: acct) }
                    emails.append(contentsOf: batch)
                } catch {
                    print("[sync] outlook fetch failed: \(error.localizedDescription)")
                }
            }
            // Newest first across the merged set.
            emails.sort { $0.received_at > $1.received_at }

            let names = sources.map(\.rawValue).sorted().joined(separator: "+")
            print("[sync] email: fetched \(emails.count) emails from \(names)")
            try await APIClient.shared.syncEmail(emails: emails)
            lastEmailSync = Date()
            print("[sync] email uploaded \(emails.count) messages")
            // Hand the indicator straight from "scanning email" to the two
            // downstream passes — begin them BEFORE ending email so the chip
            // never blinks to "done" in the gap.
            beginActivity(.insights)
            // The email report is on-demand now — only light its activity when
            // the user explicitly refreshed (force), not on background syncs.
            if force { beginActivity(.emailActions) }
            endActivity(.email)
            // Once emails land, kick off the insights extractor — Claude scans
            // the snapshot for flights / travel info and saves a bundle.
            // We update `lastInsightsRefresh` after it completes so views can
            // observe and re-fetch the insights snapshot reactively.
            Task { @MainActor in
                defer { endActivity(.insights) }
                do {
                    _ = try await APIClient.shared.refreshInsights()
                    lastInsightsRefresh = Date()
                    print("[sync] insights refreshed")
                } catch {
                    print("[sync] insights refresh failed: \(error.localizedDescription)")
                }
            }
            // Executive email action report is ON-DEMAND: it regenerates ONLY
            // on an explicit user refresh (the מוקד-המייל button or "רענן הכל"),
            // never on a background sync. Background syncs just leave the last
            // cached report in place (the card fetches it via GET on appear).
            if force {
                Task { @MainActor in
                    defer { endActivity(.emailActions) }
                    do {
                        _ = try await APIClient.shared.refreshEmailActions(force: true)
                        lastEmailActionsRefresh = Date()
                        print("[sync] email actions refreshed (on-demand)")
                    } catch {
                        print("[sync] email actions refresh failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            print("[sync] email failed: \(error.localizedDescription)")
            endActivity(.email)
        }
    }

    func syncContacts(force: Bool = false) async {
        if !force, let last = lastContactsSync, Date().timeIntervalSince(last) < contactsThrottle { return }
        let granted = await ContactsManager.shared.requestAccess()
        guard granted else { return }
        let contacts = await ContactsManager.shared.fetchAllContacts()
        do {
            try await APIClient.shared.syncContacts(contacts: contacts)
            lastContactsSync = Date()
            print("[sync] contacts uploaded \(contacts.count) contacts")
        } catch {
            print("[sync] contacts failed: \(error.localizedDescription)")
        }
    }

    func syncHealth(force: Bool = false) async {
        if !force, let last = lastHealthSync, Date().timeIntervalSince(last) < healthThrottle { return }
        let granted = await HealthManager.shared.requestAccess()
        guard granted else { return }
        await HealthManager.shared.loadToday()
        guard let summary = HealthManager.shared.summary else { return }
        do {
            try await APIClient.shared.syncHealth(summary: summary)
            lastHealthSync = Date()
            print("[sync] health uploaded")
        } catch {
            print("[sync] health failed: \(error.localizedDescription)")
        }
    }

    /// Run all syncs sequentially. Sequential (not parallel) so the user gets
    /// a single permission prompt at a time, instead of a fight on screen.
    func syncAll(force: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await syncCalendar(force: force)
        // Drain Limor's create_event outbox — writes any events whose silent
        // push iOS never delivered. Dedup-guarded, so it never duplicates an
        // event the push already created.
        await CalendarManager.shared.drainPendingEvents()
        await syncContacts(force: force)
        await syncHealth(force: force)
        await syncEmail(force: force)
    }
}
