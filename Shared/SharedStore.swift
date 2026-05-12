import Foundation

/// Shared state between the main app and the widget/Live Activity extension.
/// Backed by an App Group container so both targets can read/write.
enum SharedStore {
    static let appGroupId = "group.com.rani.Limor-Ai-App"

    /// Single shared `UserDefaults` instance for the App Group. @AppStorage
    /// observes KVO on the specific instance you hand it — if every view
    /// creates its own via `UserDefaults(suiteName:)`, writes from one
    /// don't notify observers on another, even though they all read/write
    /// the same underlying store. Stash the shared instance here so views
    /// can do `@AppStorage("key", store: SharedStore.appGroupDefaults)`.
    static let appGroupDefaults: UserDefaults =
        UserDefaults(suiteName: appGroupId) ?? .standard

    private static var defaults: UserDefaults { appGroupDefaults }

    private enum Keys {
        static let bearer = "limor.bearer"
        static let baseURL = "limor.baseURL"
        static let lat = "limor.lastLat"
        static let lng = "limor.lastLng"
        static let lastNow = "limor.lastNowJSON"
        static let photoB64 = "limor.photoB64"
        /// Legacy single-value keys — read once during migration to the new
        /// multi-source sets, then ignored. Kept around so we can recover the
        /// user's choice on first launch after the upgrade.
        static let legacyCalendarSource = "limor.calendarSource"
        static let legacyEmailSource = "limor.emailSource"
        /// New multi-source keys — store comma-separated rawValues. An empty
        /// string means "no source enabled for this kind".
        static let calendarSources = "limor.calendarSources"
        static let emailSources = "limor.emailSources"
        static let syncedReminderIds = "limor.syncedReminderIds"
        static let onboardingCompleted = "limor.onboardingCompleted"
        static let introCompleted = "limor.introCompleted"
        static let notificationPrefsAsked = "limor.notificationPrefsAsked"
        static let remindersListId = "limor.remindersListId"
        static let homeCardOrder = "limor.homeCardOrder"
        static let homeCardHidden = "limor.homeCardHidden"
        static let shoppingItems = "limor.shoppingItems" // legacy — migrated to shoppingActiveGroup
        static let shoppingActiveGroup = "limor.shoppingActiveGroup"
        static let shoppingArchive = "limor.shoppingArchive"
        static let meetingsNotifEnabled = "limor.meetingsNotif.enabled"
        static let meetingsNotifHour = "limor.meetingsNotif.hour"
        static let meetingsNotifMinute = "limor.meetingsNotif.minute"
        static let chatLocalOverlay = "limor.chatLocalOverlay"
        static let customTabKind = "limor.customTabKind"
        static let recurringReminders = "limor.recurringReminders"
        static let chatHistoryCache = "limor.chatHistoryCache"
        static let chatUsageCache = "limor.chatUsageCache"
        static let hideBirthdayEvents = "limor.hideBirthdayEvents"
    }

    static var bearer: String? {
        get { defaults.string(forKey: Keys.bearer) }
        set { defaults.set(newValue, forKey: Keys.bearer) }
    }

    static var baseURL: URL {
        get {
            if let raw = defaults.string(forKey: Keys.baseURL), let url = URL(string: raw) {
                return url
            }
            return URL(string: "http://localhost:3850")!
        }
        set { defaults.set(newValue.absoluteString, forKey: Keys.baseURL) }
    }

    static var lastCoordinate: (lat: Double, lng: Double)? {
        get {
            guard
                let lat = defaults.object(forKey: Keys.lat) as? Double,
                let lng = defaults.object(forKey: Keys.lng) as? Double
            else { return nil }
            return (lat, lng)
        }
        set {
            if let v = newValue {
                defaults.set(v.lat, forKey: Keys.lat)
                defaults.set(v.lng, forKey: Keys.lng)
            } else {
                defaults.removeObject(forKey: Keys.lat)
                defaults.removeObject(forKey: Keys.lng)
            }
        }
    }

    static func cacheLastNow(_ data: Data) {
        defaults.set(data, forKey: Keys.lastNow)
    }

    static func loadLastNow() -> NowResponse? {
        guard let data = defaults.data(forKey: Keys.lastNow) else { return nil }
        return try? JSONDecoder().decode(NowResponse.self, from: data)
    }

    /// Cached profile photo, base64 JPEG. Used by widget + tab bar avatar.
    static var photoB64: String? {
        get { defaults.string(forKey: Keys.photoB64) }
        set { defaults.set(newValue, forKey: Keys.photoB64) }
    }

    /// Where Limor reads calendar events from. Multi-select — if more than
    /// one source is enabled, SyncManager fetches from each and merges. The
    /// `.none` enum case is filtered out of the set on read/write (empty set
    /// already means "off"). First-run default is `[.apple]`.
    static var calendarSources: Set<DataSource> {
        get { readSources(key: Keys.calendarSources, legacyKey: Keys.legacyCalendarSource, default: [.apple]) }
        set { writeSources(newValue, key: Keys.calendarSources) }
    }

    /// Where Limor reads email from. Apple Mail.app has no public read API,
    /// so valid members are `.google` and `.microsoft` only. Empty set = off.
    static var emailSources: Set<DataSource> {
        get { readSources(key: Keys.emailSources, legacyKey: Keys.legacyEmailSource, default: []) }
        set { writeSources(newValue, key: Keys.emailSources) }
    }

    private static func readSources(key: String, legacyKey: String, default fallback: Set<DataSource>) -> Set<DataSource> {
        if let raw = defaults.string(forKey: key) {
            let tokens = raw.split(separator: ",").map(String.init)
            return Set(tokens.compactMap { DataSource(rawValue: $0) }).filter { $0 != .none }
        }
        // First read after the upgrade: migrate from the legacy singular key
        // (if any). Stays lazy — we only write the new key when the user
        // actually toggles something in Settings, so a no-op upgrade leaves
        // both keys untouched.
        if let legacy = defaults.string(forKey: legacyKey),
           let source = DataSource(rawValue: legacy), source != .none {
            return [source]
        }
        return fallback
    }

    private static func writeSources(_ sources: Set<DataSource>, key: String) {
        let cleaned = sources.filter { $0 != .none }
        let raw = cleaned.map(\.rawValue).sorted().joined(separator: ",")
        defaults.set(raw, forKey: key)
    }

    /// Reminder IDs we've already mirrored to iOS Reminders.app — avoids duplicates.
    static var syncedReminderIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.syncedReminderIds) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.syncedReminderIds) }
    }

    /// True once the user has been walked through the per-permission flow.
    /// While false, MainTabs is gated behind OnboardingView and auto-syncs
    /// (which trigger system permission prompts) are deferred.
    static var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Keys.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Keys.onboardingCompleted) }
    }

    /// True once the user finished the "meet Limor" intro chat after
    /// permissions onboarding. Server-side `intro_completed_at` is the
    /// source of truth; we mirror it here so cold-launch can pick the
    /// right destination without waiting for a network round-trip.
    static var introCompleted: Bool {
        get { defaults.bool(forKey: Keys.introCompleted) }
        set { defaults.set(newValue, forKey: Keys.introCompleted) }
    }

    /// True once the user has been shown the daily-notifications onboarding
    /// step (between permissions and the meet-Limor chat). Local only —
    /// the server has the actual prefs; this flag only gates the prompt.
    static var notificationPrefsAsked: Bool {
        get { defaults.bool(forKey: Keys.notificationPrefsAsked) }
        set { defaults.set(newValue, forKey: Keys.notificationPrefsAsked) }
    }

    /// The EKCalendar identifier the user has chosen for Limor reminders.
    /// Nil = use the system default (Settings → Reminders → Default List).
    static var remindersListId: String? {
        get { defaults.string(forKey: Keys.remindersListId) }
        set { defaults.set(newValue, forKey: Keys.remindersListId) }
    }

    /// Card-order preference for the home screen. Stored as raw-string IDs
    /// so the backing store stays stable across app versions even when new
    /// HomeCardKind cases are added.
    static var homeCardOrder: [String] {
        get { defaults.stringArray(forKey: Keys.homeCardOrder) ?? [] }
        set { defaults.set(newValue, forKey: Keys.homeCardOrder) }
    }

    /// Cards the user explicitly hid from the home screen. Stored separately
    /// from `homeCardOrder` so the original positions stick around — un-hiding
    /// a card later puts it right back where it was.
    static var homeCardHidden: [String] {
        get { defaults.stringArray(forKey: Keys.homeCardHidden) ?? [] }
        set { defaults.set(newValue, forKey: Keys.homeCardHidden) }
    }

    /// Local-only push notification listing tomorrow's meetings. Scheduled
    /// by `MeetingsNotifier` using `UNUserNotificationCenter` — no backend
    /// dependency, so the user can enable it even without a Limor account
    /// sync set up.
    static var meetingsNotifEnabled: Bool {
        get { defaults.bool(forKey: Keys.meetingsNotifEnabled) }
        set { defaults.set(newValue, forKey: Keys.meetingsNotifEnabled) }
    }

    /// Hour the local meetings notification fires (24h clock). Default 21:00
    /// — that's "after dinner, before the next day really starts" for most
    /// people, which is when a tomorrow-preview is most useful.
    static var meetingsNotifHour: Int {
        get { (defaults.object(forKey: Keys.meetingsNotifHour) as? Int) ?? 21 }
        set { defaults.set(newValue, forKey: Keys.meetingsNotifHour) }
    }

    static var meetingsNotifMinute: Int {
        get { defaults.integer(forKey: Keys.meetingsNotifMinute) }
        set { defaults.set(newValue, forKey: Keys.meetingsNotifMinute) }
    }

    /// Locally-persisted recurring reminders — fired by
    /// `RecurringRemindersScheduler` via UNUserNotificationCenter. Backend
    /// is intentionally not involved (the existing chat-driven `Reminder`
    /// flow doesn't support recurrence or per-reminder pause).
    static var recurringReminders: [RecurringReminder] {
        get {
            guard let data = defaults.data(forKey: Keys.recurringReminders) else { return [] }
            return (try? JSONDecoder().decode([RecurringReminder].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.recurringReminders)
            }
        }
    }

    /// Hide events that iOS Calendar marks as birthdays (the auto-generated
    /// calendar pulled from Contacts). Default true — most users have a
    /// lot of these and they crowd out actual meetings on the home card.
    /// Toggle from the MeetingsListView toolbar.
    static var hideBirthdayEvents: Bool {
        get {
            // Default to true on the very first read (no key set yet) so
            // new installs get the cleaner view automatically.
            if defaults.object(forKey: Keys.hideBirthdayEvents) == nil { return true }
            return defaults.bool(forKey: Keys.hideBirthdayEvents)
        }
        set { defaults.set(newValue, forKey: Keys.hideBirthdayEvents) }
    }

    /// Last fetched server chat history. Written after every successful
    /// `APIClient.chatHistory(token:)` so the next cold launch can render
    /// ChatView instantly — even before the new server fetch completes.
    /// Capped at the last 200 messages so the on-disk JSON stays small.
    static var chatHistoryCache: [ChatMessage] {
        get {
            guard let data = defaults.data(forKey: Keys.chatHistoryCache) else { return [] }
            return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
        }
        set {
            let capped = Array(newValue.suffix(200))
            if let data = try? JSONEncoder().encode(capped) {
                defaults.set(data, forKey: Keys.chatHistoryCache)
            }
        }
    }

    /// Last seen usage envelope from the chat history endpoint — cached so
    /// the usage badge in the toolbar can render immediately on cold launch
    /// rather than blinking in once the network fetch lands.
    static var chatUsageCache: ChatUsage? {
        get {
            guard let data = defaults.data(forKey: Keys.chatUsageCache) else { return nil }
            return try? JSONDecoder().decode(ChatUsage.self, from: data)
        }
        set {
            if let value = newValue, let data = try? JSONEncoder().encode(value) {
                defaults.set(data, forKey: Keys.chatUsageCache)
            } else {
                defaults.removeObject(forKey: Keys.chatUsageCache)
            }
        }
    }

    /// Local-only chat bubbles (shopping-list interceptions and similar
    /// purely-on-device interactions). The server's chat history endpoint
    /// doesn't know about these — without persisting them locally they'd
    /// disappear every time the user switches tabs and ChatView reloads
    /// from the server. Capped at 50 most-recent items to stay tiny.
    static var chatLocalOverlay: [ChatMessage] {
        get {
            guard let data = defaults.data(forKey: Keys.chatLocalOverlay) else { return [] }
            return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
        }
        set {
            let capped = Array(newValue.suffix(50))
            if let data = try? JSONEncoder().encode(capped) {
                defaults.set(data, forKey: Keys.chatLocalOverlay)
            }
        }
    }

    /// Optional extra tab the user can pin to the bottom tab bar (the
    /// default 4 — now, reminders, chat, settings — get a 5th of the
    /// user's choice). Empty string / nil = no extra tab.
    static var customTabKind: String? {
        get {
            let raw = defaults.string(forKey: Keys.customTabKind) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set { defaults.set(newValue ?? "", forKey: Keys.customTabKind) }
    }

    /// Currently-open shopping group. Lazily initialised — if no group has
    /// been saved yet, returns a freshly-created empty one (the user just
    /// hasn't added anything yet). On first read after the multi-group
    /// upgrade, migrates the legacy `shoppingItems` flat array into the
    /// new group shape.
    static var shoppingActiveGroup: ShoppingGroup {
        get {
            if let data = defaults.data(forKey: Keys.shoppingActiveGroup),
               let group = try? JSONDecoder().decode(ShoppingGroup.self, from: data) {
                return group
            }
            // Migration: pull any legacy flat list into a new active group.
            if let legacyData = defaults.data(forKey: Keys.shoppingItems),
               let legacyItems = try? JSONDecoder().decode([ShoppingItem].self, from: legacyData),
               !legacyItems.isEmpty {
                let migrated = ShoppingGroup(items: legacyItems)
                if let encoded = try? JSONEncoder().encode(migrated) {
                    defaults.set(encoded, forKey: Keys.shoppingActiveGroup)
                }
                defaults.removeObject(forKey: Keys.shoppingItems)
                return migrated
            }
            return ShoppingGroup()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.shoppingActiveGroup)
            }
        }
    }

    /// Archived shopping groups, newest first. The list view shows them
    /// under an expandable "רשימות קודמות" section so the user can scan
    /// what they bought last week / month.
    static var shoppingArchive: [ShoppingGroup] {
        get {
            guard let data = defaults.data(forKey: Keys.shoppingArchive) else { return [] }
            return (try? JSONDecoder().decode([ShoppingGroup].self, from: data)) ?? []
        }
        set {
            // Cap at the 20 most recent — keeps the on-disk JSON small
            // and the archive UI scannable. Older lists are evicted.
            let capped = Array(newValue.prefix(20))
            if let data = try? JSONEncoder().encode(capped) {
                defaults.set(data, forKey: Keys.shoppingArchive)
            }
        }
    }

    static func clear() {
        defaults.removeObject(forKey: Keys.bearer)
        defaults.removeObject(forKey: Keys.lastNow)
        defaults.removeObject(forKey: Keys.photoB64)
        defaults.removeObject(forKey: Keys.syncedReminderIds)
    }
}
