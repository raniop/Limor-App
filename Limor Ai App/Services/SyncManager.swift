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
    @Published private(set) var isSyncing = false

    // MARK: - Background activity status (home-screen "Limor is working" chip)

    /// A discrete thing Limor is doing in the background. The home screen
    /// surfaces a friendly label so the user knows work is happening (e.g.
    /// "מחפשת טיסות") instead of waiting on a card that silently appears.
    enum LimorActivity: String, CaseIterable, Hashable {
        case email, insights, emailActions

        /// Present-tense label shown while the activity runs ("לימור …").
        var working: String {
            switch self {
            case .email:        return "סורקת את המייל שלך"
            case .insights:     return "מחפשת טיסות ותובנות"
            case .emailActions: return "עוברת על המשימות מהמייל"
            }
        }

        /// Lower = higher priority when choosing which label to headline.
        var order: Int {
            switch self {
            case .email:        return 0
            case .insights:     return 1
            case .emailActions: return 2
            }
        }
    }

    /// Currently-running background activities.
    @Published private(set) var activities: Set<LimorActivity> = []

    /// A friendly "all done" line shown after a batch of activity finishes.
    /// Deliberately *persists* (doesn't vanish) until the next activity
    /// starts — closes the loop so the user sees Limor actually finished,
    /// rather than the indicator just disappearing.
    @Published private(set) var lastActivitySummary: String?

    /// Activities seen since the indicator was last idle — used to compose
    /// the done message describing what just happened.
    private var ranThisBatch: Set<LimorActivity> = []

    /// The single most relevant in-progress label, or nil when idle.
    var activityHeadline: String? {
        activities.sorted { $0.order < $1.order }.first?.working
    }

    private func beginActivity(_ a: LimorActivity) {
        lastActivitySummary = nil   // a fresh batch supersedes the old "done"
        ranThisBatch.insert(a)
        activities.insert(a)
    }

    private func endActivity(_ a: LimorActivity) {
        activities.remove(a)
        if activities.isEmpty {
            lastActivitySummary = doneMessage(for: ranThisBatch)
            ranThisBatch.removeAll()
        }
    }

    private func doneMessage(for ran: Set<LimorActivity>) -> String {
        if ran.contains(.insights) || ran.contains(.emailActions) {
            return "עברתי על המייל ועדכנתי הכול ✨"
        }
        if ran.contains(.email) {
            return "סיימתי לסרוק את המייל ✨"
        }
        return "הכול מעודכן ✨"
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
                    emails.append(contentsOf: try await GoogleAPIs.fetchRecentEmails(daysBack: 14, limit: 60))
                } catch {
                    print("[sync] gmail fetch failed: \(error.localizedDescription)")
                }
            }
            if sources.contains(.microsoft) {
                let granted = MicrosoftAPIs.grantedScopes()
                print("[sync] email: starting Outlook fetch. Granted MS scopes: \(granted)")
                do {
                    emails.append(contentsOf: try await MicrosoftAPIs.fetchRecentEmails(daysBack: 14, limit: 60))
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
            beginActivity(.emailActions)
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
            // Executive email action report — server enforces a 24h cooldown,
            // so this cheap call no-ops most of the time and only burns Sonnet
            // once a day. Bumps `lastEmailActionsRefresh` so the card re-fetches.
            Task { @MainActor in
                defer { endActivity(.emailActions) }
                do {
                    _ = try await APIClient.shared.refreshEmailActions(force: false)
                    lastEmailActionsRefresh = Date()
                    print("[sync] email actions refreshed")
                } catch {
                    print("[sync] email actions refresh failed: \(error.localizedDescription)")
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
        await syncContacts(force: force)
        await syncHealth(force: force)
        await syncEmail(force: force)
    }
}
