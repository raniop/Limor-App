import Foundation

/// Shared state between the main app and the widget/Live Activity extension.
/// Backed by an App Group container so both targets can read/write.
enum SharedStore {
    static let appGroupId = "group.com.rani.Limor-Ai-App"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupId) ?? .standard
    }

    private enum Keys {
        static let bearer = "limor.bearer"
        static let baseURL = "limor.baseURL"
        static let lat = "limor.lastLat"
        static let lng = "limor.lastLng"
        static let lastNow = "limor.lastNowJSON"
        static let photoB64 = "limor.photoB64"
        static let calendarSource = "limor.calendarSource"
        static let emailSource = "limor.emailSource"
        static let syncedReminderIds = "limor.syncedReminderIds"
        static let onboardingCompleted = "limor.onboardingCompleted"
        static let remindersListId = "limor.remindersListId"
        static let homeCardOrder = "limor.homeCardOrder"
        static let homeCardHidden = "limor.homeCardHidden"
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

    /// Where Limor reads calendar events from.
    static var calendarSource: DataSource {
        get { DataSource(rawValue: defaults.string(forKey: Keys.calendarSource) ?? "") ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: Keys.calendarSource) }
    }

    /// Where Limor reads email from. Apple Mail.app has no public read API,
    /// so the only real option here is Google or none.
    static var emailSource: DataSource {
        get { DataSource(rawValue: defaults.string(forKey: Keys.emailSource) ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: Keys.emailSource) }
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

    static func clear() {
        defaults.removeObject(forKey: Keys.bearer)
        defaults.removeObject(forKey: Keys.lastNow)
        defaults.removeObject(forKey: Keys.photoB64)
        defaults.removeObject(forKey: Keys.syncedReminderIds)
    }
}
