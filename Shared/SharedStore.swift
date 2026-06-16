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
        static let cachedReminders = "limor.cachedRemindersJSON"
        static let cachedTasks = "limor.cachedTasksJSON"
        static let cachedMeetings = "limor.cachedMeetingsJSON"
        static let photoB64 = "limor.photoB64"
        static let appLang = "limor.appLang"
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
        /// Map Limor reminder id → EKReminder calendarItemIdentifier, so
        /// completing or deleting in Limor can flip the EK side too.
        static let syncedReminderEkIds = "limor.syncedReminderEkIds"
        static let syncedReminderEventIds = "limor.syncedReminderEventIds"
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
        static let leadTimeNotifEnabled = "limor.leadNotif.enabled"
        static let departureNotifEnabled = "limor.departureNotif.enabled"
        static let notificationSoundName = "limor.notifSoundName"
        static let quietHoursEnabled = "limor.quietHours.enabled"
        static let quietStartHour = "limor.quietHours.start"
        static let quietEndHour = "limor.quietHours.end"
        static let chatLocalOverlay = "limor.chatLocalOverlay"
        static let customTabKind = "limor.customTabKind"
        static let recurringReminders = "limor.recurringReminders"
        static let chatHistoryCache = "limor.chatHistoryCache"
        static let chatUsageCache = "limor.chatUsageCache"
        static let hideBirthdayEvents = "limor.hideBirthdayEvents"
        static let dismissedFlightIds = "limor.dismissedFlightIds"
        static let dismissedEmailActionKeys = "limor.dismissedEmailActionKeys"
        // event_id's of create_event outbox items already written to EventKit —
        // the dedup guard shared by the silent push + the outbox drain.
        static let createdCalendarEventIds = "limor.createdCalendarEventIds"
    }

    static var bearer: String? {
        get { defaults.string(forKey: Keys.bearer) }
        set { defaults.set(newValue, forKey: Keys.bearer) }
    }

    /// Firebase refresh token + API key — let the Share extension mint a fresh
    /// 1h id token on its own (via the Secure Token API) when the cached
    /// `bearer` has expired, instead of failing and forcing an app open.
    static var firebaseRefreshToken: String? {
        get { defaults.string(forKey: "limor.fbRefreshToken") }
        set { defaults.set(newValue, forKey: "limor.fbRefreshToken") }
    }
    static var firebaseApiKey: String? {
        get { defaults.string(forKey: "limor.fbApiKey") }
        set { defaults.set(newValue, forKey: "limor.fbApiKey") }
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

    /// Raw cached snapshot — used by `WatchSyncManager` so it can ship
    /// the bytes over WCSession without decoding-then-re-encoding.
    static func lastNowJSONData() -> Data? {
        defaults.data(forKey: Keys.lastNow)
    }

    // MARK: - Reminders mirror (for watch)

    static func cacheReminders(_ list: [Reminder]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Keys.cachedReminders)
        }
    }

    static func loadReminders() -> [Reminder] {
        guard let data = defaults.data(forKey: Keys.cachedReminders) else { return [] }
        return (try? JSONDecoder().decode([Reminder].self, from: data)) ?? []
    }

    static func cachedRemindersData() -> Data? {
        defaults.data(forKey: Keys.cachedReminders)
    }

    static func setCachedRemindersData(_ data: Data) {
        defaults.set(data, forKey: Keys.cachedReminders)
    }

    // MARK: - Tasks cache (for the widget — read from the App Group)

    static func cacheTasks(_ list: [LimorTask]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Keys.cachedTasks)
        }
    }

    static func loadTasks() -> [LimorTask] {
        guard let data = defaults.data(forKey: Keys.cachedTasks) else { return [] }
        return (try? JSONDecoder().decode([LimorTask].self, from: data)) ?? []
    }

    // MARK: - Meetings mirror (for watch)

    static func cacheMeetings(_ events: [CalendarEventDTO]) {
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Keys.cachedMeetings)
        }
    }

    static func loadMeetings() -> [CalendarEventDTO] {
        guard let data = defaults.data(forKey: Keys.cachedMeetings) else { return [] }
        return (try? JSONDecoder().decode([CalendarEventDTO].self, from: data)) ?? []
    }

    static func cachedMeetingsData() -> Data? {
        defaults.data(forKey: Keys.cachedMeetings)
    }

    static func setCachedMeetingsData(_ data: Data) {
        defaults.set(data, forKey: Keys.cachedMeetings)
    }

    /// Cached profile photo, base64 JPEG. Used by widget + tab bar avatar.
    static var photoB64: String? {
        get { defaults.string(forKey: Keys.photoB64) }
        set { defaults.set(newValue, forKey: Keys.photoB64) }
    }

    /// UI language ("he" / "en"). Lives in the App Group so the widget, share
    /// extension, and on-device notification builders all render in the same
    /// language the user picked in the app. Defaults to Hebrew.
    static var appLang: String {
        get { defaults.string(forKey: Keys.appLang) ?? "he" }
        set { defaults.set(newValue, forKey: Keys.appLang) }
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
        func parse(_ raw: String) -> Set<DataSource> {
            Set(raw.split(separator: ",").map(String.init).compactMap { DataSource(rawValue: $0) }).filter { $0 != .none }
        }
        if let raw = defaults.string(forKey: key) {
            return parse(raw)
        }
        // Not set locally yet (fresh install on a second device) — pull the
        // choice the user already made elsewhere from iCloud KVS and cache it.
        if let cloud = iCloud, let raw = cloud.string(forKey: key) {
            defaults.set(raw, forKey: key)
            return parse(raw)
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
        iCloud?.set(raw, forKey: key)   // sync the choice across the user's devices
    }

    /// Reminder IDs we've already mirrored to iOS Reminders.app — avoids duplicates.
    static var syncedReminderIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.syncedReminderIds) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.syncedReminderIds) }
    }

    /// Map of Limor reminder id → EKReminder calendarItemIdentifier on this
    /// device. Populated when `RemindersWriter` mirrors a reminder so a
    /// later "complete" / "delete" in Limor can find and update the
    /// matching `EKReminder`. Stored as `[String: String]` in defaults.
    static var syncedReminderEkIds: [String: String] {
        get { (defaults.dictionary(forKey: Keys.syncedReminderEkIds) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.syncedReminderEkIds) }
    }

    /// Map of Limor reminder id → EKEvent `eventIdentifier`. Parallel to
    /// `syncedReminderEkIds`, but for the Apple Calendar (event) mirror
    /// that `CalendarManager` writes alongside the Reminders one. Lets
    /// "delete this reminder" wipe both sides instead of leaving a ghost
    /// calendar block on the user's day.
    static var syncedReminderEventIds: [String: String] {
        get { (defaults.dictionary(forKey: Keys.syncedReminderEventIds) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.syncedReminderEventIds) }
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

    /// Manual color overrides for task tags: tag name → "#RRGGBB". Tags without
    /// an override fall back to a deterministic color derived from the name.
    static var tagColorHex: [String: String] {
        get { (defaults.dictionary(forKey: "limor.tagColors") as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: "limor.tagColors") }
    }

    /// Local-only push notification listing tomorrow's meetings. Scheduled
    /// by `MeetingsNotifier` using `UNUserNotificationCenter` — no backend
    /// dependency, so the user can enable it even without a Limor account
    /// sync set up.
    static var meetingsNotifEnabled: Bool {
        get { defaults.bool(forKey: Keys.meetingsNotifEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.meetingsNotifEnabled)
            iCloud?.set(newValue, forKey: Keys.meetingsNotifEnabled)
        }
    }

    /// Hour the local meetings notification fires (24h clock). Default 21:00
    /// — that's "after dinner, before the next day really starts" for most
    /// people, which is when a tomorrow-preview is most useful.
    static var meetingsNotifHour: Int {
        get { (defaults.object(forKey: Keys.meetingsNotifHour) as? Int) ?? 21 }
        set {
            defaults.set(newValue, forKey: Keys.meetingsNotifHour)
            iCloud?.set(Int64(newValue), forKey: Keys.meetingsNotifHour)
        }
    }

    static var meetingsNotifMinute: Int {
        get { defaults.integer(forKey: Keys.meetingsNotifMinute) }
        set {
            defaults.set(newValue, forKey: Keys.meetingsNotifMinute)
            iCloud?.set(Int64(newValue), forKey: Keys.meetingsNotifMinute)
        }
    }

    /// Local-only "heads-up" notification fired 2h before each upcoming
    /// meeting AND each pending reminder. Scheduled by `LeadTimeNotifier`
    /// via `UNUserNotificationCenter` — additive to the backend's
    /// at-due-time reminder push and to MeetingsNotifier's evening digest.
    /// Defaults to ON so the user gets the lead-time heads-up out of the box.
    static var leadTimeNotifEnabled: Bool {
        get { (defaults.object(forKey: Keys.leadTimeNotifEnabled) as? Bool) ?? true }
        set {
            defaults.set(newValue, forKey: Keys.leadTimeNotifEnabled)
            iCloud?.set(newValue, forKey: Keys.leadTimeNotifEnabled)
        }
    }

    /// "Time to leave" notifications for meetings that have an address —
    /// computed on-device from the driving ETA. Default ON.
    static var departureNotifEnabled: Bool {
        get { (defaults.object(forKey: Keys.departureNotifEnabled) as? Bool) ?? true }
        set {
            defaults.set(newValue, forKey: Keys.departureNotifEnabled)
            iCloud?.set(newValue, forKey: Keys.departureNotifEnabled)
        }
    }

    /// Chosen notification sound — a bundled `.caf` filename ("bell.caf"), or
    /// nil for the default iOS sound. Mirrors `NotificationPrefsDoc.sound`
    /// (server-synced for push); local notifiers (lead-time, meetings) read
    /// it here to set `content.sound`. Synced via iCloud across devices.
    static var notificationSoundName: String? {
        get { defaults.string(forKey: Keys.notificationSoundName) }
        set {
            defaults.set(newValue, forKey: Keys.notificationSoundName)
            iCloud?.set(newValue, forKey: Keys.notificationSoundName)
        }
    }

    /// Night-quiet window. Defaults ON 23:00→07:00 — a safety net so automated
    /// notifications never wake the user. Local notifiers (lead-time) skip fire
    /// times inside it; the backend enforces it for daily pushes.
    static var quietHoursEnabled: Bool {
        get { (defaults.object(forKey: Keys.quietHoursEnabled) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: Keys.quietHoursEnabled); iCloud?.set(newValue, forKey: Keys.quietHoursEnabled) }
    }
    static var quietStartHour: Int {
        get { (defaults.object(forKey: Keys.quietStartHour) as? Int) ?? 23 }
        set { defaults.set(newValue, forKey: Keys.quietStartHour); iCloud?.set(Int64(newValue), forKey: Keys.quietStartHour) }
    }
    static var quietEndHour: Int {
        get { (defaults.object(forKey: Keys.quietEndHour) as? Int) ?? 7 }
        set { defaults.set(newValue, forKey: Keys.quietEndHour); iCloud?.set(Int64(newValue), forKey: Keys.quietEndHour) }
    }

    /// True if `date`'s local hour falls inside the enabled quiet window.
    /// Handles a window that wraps past midnight (start > end, e.g. 23→7).
    static func isWithinQuietHours(_ date: Date) -> Bool {
        guard quietHoursEnabled else { return false }
        let start = quietStartHour, end = quietEndHour
        if start == end { return false }
        let hour = Calendar.current.component(.hour, from: date)
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    /// Locally-persisted recurring reminders — fired by
    /// `RecurringRemindersScheduler` via UNUserNotificationCenter on
    /// each device. Synced via iCloud KVS so adding a recurring
    /// reminder on one device shows up on the user's other devices
    /// (each one schedules its own UNNotificationRequests from the
    /// shared list, which is what we want).
    static var recurringReminders: [RecurringReminder] {
        get {
            guard let data = defaults.data(forKey: Keys.recurringReminders) else { return [] }
            return (try? JSONDecoder().decode([RecurringReminder].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.recurringReminders)
                if let cloud = iCloud {
                    cloud.set(data, forKey: Keys.recurringReminders)
                    cloud.synchronize()
                    print("[icloud] wrote recurring reminders (\(data.count)B)")
                }
            }
        }
    }

    /// Mirror recurring reminders from iCloud → local. Same first-run
    /// migration shape as shopping: if iCloud is empty but local has
    /// data, push local up.
    static func mirrorRemindersFromICloud() {
        guard let cloud = iCloud else { return }
        cloud.synchronize()
        let cloudData = cloud.data(forKey: Keys.recurringReminders)
        let localData = defaults.data(forKey: Keys.recurringReminders)
        if let data = cloudData {
            defaults.set(data, forKey: Keys.recurringReminders)
        } else if let data = localData {
            cloud.set(data, forKey: Keys.recurringReminders)
            cloud.synchronize()
            print("[icloud] mirror: pushed local recurring reminders up (\(data.count)B)")
        }
    }

    /// Sync the "tomorrow's meetings" notification prefs (enabled / hour /
    /// minute) so a user who set 21:00 on the simulator gets the same
    /// schedule on the iPhone without re-configuring.
    static func mirrorMeetingsNotifFromICloud() {
        guard let cloud = iCloud else { return }
        cloud.synchronize()
        if cloud.object(forKey: Keys.meetingsNotifEnabled) != nil {
            defaults.set(cloud.bool(forKey: Keys.meetingsNotifEnabled),
                         forKey: Keys.meetingsNotifEnabled)
        } else if defaults.object(forKey: Keys.meetingsNotifEnabled) != nil {
            cloud.set(defaults.bool(forKey: Keys.meetingsNotifEnabled),
                      forKey: Keys.meetingsNotifEnabled)
        }
        if cloud.object(forKey: Keys.meetingsNotifHour) != nil {
            defaults.set(cloud.longLong(forKey: Keys.meetingsNotifHour),
                         forKey: Keys.meetingsNotifHour)
        } else if defaults.object(forKey: Keys.meetingsNotifHour) != nil {
            cloud.set(Int64(defaults.integer(forKey: Keys.meetingsNotifHour)),
                      forKey: Keys.meetingsNotifHour)
        }
        if cloud.object(forKey: Keys.meetingsNotifMinute) != nil {
            defaults.set(cloud.longLong(forKey: Keys.meetingsNotifMinute),
                         forKey: Keys.meetingsNotifMinute)
        } else if defaults.object(forKey: Keys.meetingsNotifMinute) != nil {
            cloud.set(Int64(defaults.integer(forKey: Keys.meetingsNotifMinute)),
                      forKey: Keys.meetingsNotifMinute)
        }
        if cloud.object(forKey: Keys.leadTimeNotifEnabled) != nil {
            defaults.set(cloud.bool(forKey: Keys.leadTimeNotifEnabled),
                         forKey: Keys.leadTimeNotifEnabled)
        } else if defaults.object(forKey: Keys.leadTimeNotifEnabled) != nil {
            cloud.set(defaults.bool(forKey: Keys.leadTimeNotifEnabled),
                      forKey: Keys.leadTimeNotifEnabled)
        }
        cloud.synchronize()
    }

    /// Set of flight insight IDs the user explicitly dismissed (e.g. phantom
    /// flights the AI extractor mis-identified from an old email). Filtered
    /// out by NowView's upcomingFlight picker. Persisted locally + iCloud.
    static var dismissedFlightIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.dismissedFlightIds) ?? []) }
        set {
            let arr = Array(newValue)
            defaults.set(arr, forKey: Keys.dismissedFlightIds)
            iCloud?.set(arr, forKey: Keys.dismissedFlightIds)
        }
    }

    /// Stable keys of executive-email action items the user marked "handled".
    /// Keyed by the item's source email (or a content hash) so a dismissal
    /// survives the daily report regeneration — the same email surfacing
    /// again stays hidden. Persisted locally + iCloud.
    static var dismissedEmailActionKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.dismissedEmailActionKeys) ?? []) }
        set {
            let arr = Array(newValue)
            defaults.set(arr, forKey: Keys.dismissedEmailActionKeys)
            iCloud?.set(arr, forKey: Keys.dismissedEmailActionKeys)
        }
    }

    /// event_id's of create_event outbox items already written to this device's
    /// calendar. Both the silent-push handler and the outbox drain check this
    /// before writing, so an event is never created twice. Local only — each
    /// device tracks its own EventKit writes.
    static var createdCalendarEventIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.createdCalendarEventIds) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.createdCalendarEventIds) }
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
    /// Mirrored to iCloud KVS so the simulator's "🛒 הוספתי..." bubbles
    /// show up on the iPhone too — without that, the user sees the
    /// interception only on the device that triggered it.
    static var chatLocalOverlay: [ChatMessage] {
        get {
            guard let data = defaults.data(forKey: Keys.chatLocalOverlay) else { return [] }
            return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
        }
        set {
            let capped = Array(newValue.suffix(50))
            if let data = try? JSONEncoder().encode(capped) {
                defaults.set(data, forKey: Keys.chatLocalOverlay)
                iCloud?.set(data, forKey: Keys.chatLocalOverlay)
            }
        }
    }

    /// Mirror the chat overlay from iCloud → local. Called on launch and
    /// scenePhase=.active so shopping-list interception bubbles from
    /// other devices land in the chat tab.
    static func mirrorChatOverlayFromICloud() {
        guard let cloud = iCloud else { return }
        cloud.synchronize()
        if let data = cloud.data(forKey: Keys.chatLocalOverlay) {
            defaults.set(data, forKey: Keys.chatLocalOverlay)
        } else if let local = defaults.data(forKey: Keys.chatLocalOverlay) {
            cloud.set(local, forKey: Keys.chatLocalOverlay)
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

    /// iCloud Key-Value Store — synced across the user's Apple devices
    /// (when they're signed into the same iCloud account). We mirror the
    /// shopping list here so the user sees the same items on simulator
    /// and iPhone without any backend involvement. Falls back to nil if
    /// iCloud is unavailable (entitlement missing, signed out, etc.).
    private static let iCloud: NSUbiquitousKeyValueStore? = {
        let store = NSUbiquitousKeyValueStore.default
        store.synchronize()
        return store
    }()

    /// Run all iCloud KVS mirror passes — shopping + recurring reminders
    /// + meetings-notification prefs — in one call. Cheap; ok to invoke
    /// from `scenePhase=.active` and the change-externally notification.
    static func mirrorAllFromICloud() {
        mirrorShoppingFromICloud()
        mirrorRemindersFromICloud()
        mirrorMeetingsNotifFromICloud()
        mirrorChatOverlayFromICloud()
    }

    /// Pull the latest shopping data from iCloud into local UserDefaults.
    /// On the very first run that has iCloud available, if local has data
    /// but iCloud doesn't, push local up to iCloud — that's the one-time
    /// migration for users who built up shopping/archive before the
    /// entitlement was added.
    static func mirrorShoppingFromICloud() {
        guard let cloud = iCloud else {
            print("[icloud] mirror: NSUbiquitousKeyValueStore.default is nil — entitlement missing or iCloud unavailable")
            return
        }
        let synced = cloud.synchronize()
        let activeData = cloud.data(forKey: Keys.shoppingActiveGroup)
        let archiveData = cloud.data(forKey: Keys.shoppingArchive)
        let localActive = defaults.data(forKey: Keys.shoppingActiveGroup)
        let localArchive = defaults.data(forKey: Keys.shoppingArchive)
        print("[icloud] mirror: synchronize=\(synced) icloud(active=\(activeData?.count ?? 0)B,archive=\(archiveData?.count ?? 0)B) local(active=\(localActive?.count ?? 0)B,archive=\(localArchive?.count ?? 0)B)")

        if let cloudData = activeData {
            defaults.set(cloudData, forKey: Keys.shoppingActiveGroup)
        } else if let localData = localActive {
            // iCloud has nothing but local does — push local up so the
            // user's existing list syncs to other devices.
            cloud.set(localData, forKey: Keys.shoppingActiveGroup)
            print("[icloud] mirror: pushed local active group up (\(localData.count)B)")
        }
        if let cloudData = archiveData {
            defaults.set(cloudData, forKey: Keys.shoppingArchive)
        } else if let localData = localArchive {
            cloud.set(localData, forKey: Keys.shoppingArchive)
            print("[icloud] mirror: pushed local archive up (\(localData.count)B)")
        }
        cloud.synchronize()
    }

    /// Currently-open shopping group. Lazily initialised — if no group has
    /// been saved yet, returns a freshly-created empty one (the user just
    /// hasn't added anything yet). Migrates the legacy `shoppingItems`
    /// flat array on first read. Writes dual-write to App Group
    /// UserDefaults (instant local read) AND iCloud KVS (cross-device).
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
                    iCloud?.set(encoded, forKey: Keys.shoppingActiveGroup)
                }
                defaults.removeObject(forKey: Keys.shoppingItems)
                return migrated
            }
            return ShoppingGroup()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.shoppingActiveGroup)
                if let cloud = iCloud {
                    cloud.set(data, forKey: Keys.shoppingActiveGroup)
                    let synced = cloud.synchronize()
                    print("[icloud] wrote active group (\(data.count)B) synchronize=\(synced)")
                } else {
                    print("[icloud] wrote active group LOCAL ONLY — iCloud nil")
                }
            }
        }
    }

    /// Archived shopping groups, newest first. The list view shows them
    /// under an expandable "רשימות קודמות" section so the user can scan
    /// what they bought last week / month. Mirrored to iCloud KVS.
    static var shoppingArchive: [ShoppingGroup] {
        get {
            guard let data = defaults.data(forKey: Keys.shoppingArchive) else { return [] }
            return (try? JSONDecoder().decode([ShoppingGroup].self, from: data)) ?? []
        }
        set {
            let capped = Array(newValue.prefix(20))
            if let data = try? JSONEncoder().encode(capped) {
                defaults.set(data, forKey: Keys.shoppingArchive)
                if let cloud = iCloud {
                    cloud.set(data, forKey: Keys.shoppingArchive)
                    let synced = cloud.synchronize()
                    print("[icloud] wrote archive (\(data.count)B) synchronize=\(synced)")
                }
            }
        }
    }

    static func clear() {
        defaults.removeObject(forKey: Keys.bearer)
        defaults.removeObject(forKey: Keys.lastNow)
        defaults.removeObject(forKey: Keys.photoB64)
        defaults.removeObject(forKey: Keys.syncedReminderIds)
        defaults.removeObject(forKey: Keys.syncedReminderEkIds)
        defaults.removeObject(forKey: Keys.syncedReminderEventIds)
    }
}
