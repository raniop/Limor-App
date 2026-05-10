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
    @Published private(set) var isSyncing = false

    /// Per-type throttle. Email/insights are the most "fresh data" sensitive,
    /// so they re-run more frequently. Contacts barely change → longer.
    private let emailThrottle: TimeInterval = 15 * 60   // 15 minutes
    private let calendarThrottle: TimeInterval = 30 * 60
    private let healthThrottle: TimeInterval = 30 * 60
    private let contactsThrottle: TimeInterval = 6 * 60 * 60   // 6 hours
    private let throttleSeconds: TimeInterval = 30 * 60        // legacy default

    func syncCalendar(force: Bool = false) async {
        if !force, let last = lastCalendarSync, Date().timeIntervalSince(last) < calendarThrottle { return }

        let events: [CalendarEventDTO]
        switch SharedStore.calendarSource {
        case .google:
            do {
                events = try await GoogleAPIs.fetchCalendarEvents()
            } catch {
                print("[sync] google calendar failed: \(error.localizedDescription)")
                return
            }
        case .apple, .none:
            let granted = await CalendarManager.shared.requestAccess()
            guard granted else { return }
            events = CalendarManager.shared.fetchUpcomingEvents()
        }

        do {
            try await APIClient.shared.syncCalendar(events: events)
            lastCalendarSync = Date()
            print("[sync] calendar (\(SharedStore.calendarSource.rawValue)) uploaded \(events.count) events")
        } catch {
            print("[sync] calendar upload failed: \(error.localizedDescription)")
        }
    }

    func syncEmail(force: Bool = false) async {
        guard SharedStore.emailSource == .google else {
            print("[sync] email: source is \(SharedStore.emailSource.rawValue), skipping")
            return
        }
        if !force, let last = lastEmailSync, Date().timeIntervalSince(last) < emailThrottle {
            print("[sync] email: throttled (last=\(last))")
            return
        }
        let granted = await MainActor.run { GoogleAPIs.grantedScopes() }
        print("[sync] email: starting fetch. Granted Google scopes: \(granted)")
        do {
            let emails = try await GoogleAPIs.fetchRecentEmails(daysBack: 7, limit: 25)
            print("[sync] email: fetched \(emails.count) emails from Gmail API")
            try await APIClient.shared.syncEmail(emails: emails)
            lastEmailSync = Date()
            print("[sync] email uploaded \(emails.count) messages")
            // Once emails land, kick off the insights extractor — Claude scans
            // the snapshot for flights / travel info and saves a bundle.
            // We update `lastInsightsRefresh` after it completes so views can
            // observe and re-fetch the insights snapshot reactively.
            Task { @MainActor in
                do {
                    _ = try await APIClient.shared.refreshInsights()
                    lastInsightsRefresh = Date()
                    print("[sync] insights refreshed")
                } catch {
                    print("[sync] insights refresh failed: \(error.localizedDescription)")
                }
            }
        } catch {
            print("[sync] email failed: \(error.localizedDescription)")
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
