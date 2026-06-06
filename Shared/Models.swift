import Foundation

enum DataSource: String, Codable, CaseIterable {
    case apple
    case google
    case microsoft
    case none
}

struct UserProfile: Codable {
    let id: String
    let email: String?
    let display_name: String?
    let photo_b64: String?
}

struct UserProfileEnvelope: Decodable { let user: UserProfile }

struct WorkoutSummary: Codable, Hashable, Identifiable {
    var id: String { "\(activity_name)-\(start_at)" }
    let activity_name: String          // e.g. "ריצה", "אופניים"
    let activity_symbol: String        // SF Symbol name
    let start_at: String               // ISO
    let duration_minutes: Double
    let calories_kcal: Double?
    let distance_km: Double?
    let avg_heart_rate: Int?
}

struct HealthSummary: Codable, Hashable {
    // Activity rings
    let steps: Int?
    let active_calories_kcal: Double?
    let resting_calories_kcal: Double?
    let distance_km: Double?
    let exercise_minutes: Int?
    let stand_hours: Int?

    // Heart
    let resting_heart_rate: Int?
    let walking_heart_rate_avg: Int?
    let heart_rate_variability_ms: Double?

    // Fitness
    let vo2_max: Double?

    // Body
    let weight_kg: Double?
    let body_fat_percent: Double?

    // Sleep last night
    let sleep_hours: Double?
    /// ISO timestamp the user fell asleep (earliest "asleep" sample). Nullable.
    let sleep_bedtime_iso: String?
    /// ISO timestamp the user woke up (latest "asleep" sample). Nullable.
    let sleep_wake_time_iso: String?
    /// Mean sleep hours across the last 7 nights with data. Nullable when
    /// sample size is too small (< 3 nights of data).
    let sleep_avg_hours_last_7: Double?

    // Mindfulness
    let mindful_minutes: Double?

    // Workouts
    let last_workout: WorkoutSummary?
    let workouts_this_week: Int?
    let workout_minutes_this_week: Double?

    let date: String        // YYYY-MM-DD
}

struct AuthResponse: Decodable {
    let token: String
    let user: User

    struct User: Decodable {
        let id: String
        let email: String?
        let display_name: String?
    }
}

struct Reminder: Codable, Identifiable, Hashable {
    let id: String
    let task: String
    let due_at: String
    let status: Status
    let created_at: String
    let completed_at: String?
    let msUntilDue: Double
    let isOverdue: Bool

    enum Status: String, Codable, Hashable {
        case pending, completed
    }

    var dueDate: Date {
        ISO8601DateFormatter.limor.date(from: due_at) ?? Date()
    }
}

struct ReminderEnvelope: Decodable { let reminder: Reminder }
struct RemindersEnvelope: Decodable { let reminders: [Reminder] }

struct Weather: Codable, Hashable {
    let temp_c: Double
    let feels_like_c: Double
    let condition: String
    let icon: String
    let high_c: Double?
    let low_c: Double?
    let fetched_at: String
    let lat: Double
    let lng: Double
}

struct WeatherDetail: Codable, Hashable {
    let current: CurrentWeather
    let hourly: [HourlyForecast]
    let daily: [DailyForecast]

    struct CurrentWeather: Codable, Hashable {
        let temp_c: Double
        let feels_like_c: Double
        let condition: String
        let icon: String
        let humidity_percent: Int?
        let wind_speed_kmh: Double?
        let wind_direction_deg: Double?
        let uv_index: Double?
        let visibility_km: Double?
        let precipitation_mm: Double?
        let fetched_at: String
        let lat: Double
        let lng: Double
        let timezone: String?
    }

    struct HourlyForecast: Codable, Hashable, Identifiable {
        var id: String { time }
        let time: String
        let temp_c: Double
        let precipitation_probability: Int?
        let icon: String
        let condition: String
    }

    struct DailyForecast: Codable, Hashable, Identifiable {
        var id: String { date }
        let date: String
        let max_temp_c: Double
        let min_temp_c: Double
        let icon: String
        let condition: String
        let sunrise: String?
        let sunset: String?
        let precipitation_probability_max: Int?
    }
}

struct NowResponse: Codable {
    let next_reminder: Reminder?
    let weather: Weather?
    let user: User
    let updated_at: String

    struct User: Codable { let display_name: String? }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable, Hashable { case user, assistant }
    var id: String { "\(role.rawValue)-\(created_at)-\(content.hashValue)" }
    let role: Role
    let content: String
    let created_at: String
    /// Locally attached image data — only set on optimistic messages for preview
    /// in the bubble. Not decoded from server responses.
    var localAttachmentImageData: Data? = nil
    /// Locally attached document filename — same caveats.
    var localAttachmentFilename: String? = nil
    /// Locally recorded voice-message URL — set on the user's own
    /// optimistic bubble so the chat can render a play button + duration
    /// without round-tripping to the server. The *file itself* lives in
    /// `voiceMessagesDirectory` (a stable Caches subfolder), so the
    /// audio survives history reloads even though the full URL is
    /// sandbox-relative and rebuilt on decode from the saved filename.
    var localAudioURL: URL? = nil
    var localAudioDuration: TimeInterval? = nil

    /// Codable round-trips the audio filename (basename) + duration so
    /// voice bubbles persisted to `SharedStore.chatLocalOverlay` come
    /// back with a working play button after the chat tab is
    /// re-entered, instead of degrading into an empty/text bubble.
    /// Image attachments are still view-only — too large to stash.
    private enum CodingKeys: String, CodingKey {
        case role, content, created_at, local_audio_filename, local_audio_duration
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(created_at, forKey: .created_at)
        if let filename = localAudioURL?.lastPathComponent {
            try c.encode(filename, forKey: .local_audio_filename)
        }
        if let duration = localAudioDuration {
            try c.encode(duration, forKey: .local_audio_duration)
        }
    }

    init(role: Role, content: String, created_at: String,
         localAttachmentImageData: Data? = nil,
         localAttachmentFilename: String? = nil,
         localAudioURL: URL? = nil,
         localAudioDuration: TimeInterval? = nil) {
        self.role = role
        self.content = content
        self.created_at = created_at
        self.localAttachmentImageData = localAttachmentImageData
        self.localAttachmentFilename = localAttachmentFilename
        self.localAudioURL = localAudioURL
        self.localAudioDuration = localAudioDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try c.decode(Role.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.created_at = try c.decode(String.self, forKey: .created_at)
        self.localAttachmentImageData = nil
        self.localAttachmentFilename = nil
        // Re-resolve the audio URL against the current sandbox so the
        // play button works even though the sandbox path may have
        // changed between launches. We only stored the filename.
        if let filename = try c.decodeIfPresent(String.self, forKey: .local_audio_filename) {
            self.localAudioURL = ChatMessage.voiceMessagesDirectory
                .appendingPathComponent(filename)
        } else {
            self.localAudioURL = nil
        }
        self.localAudioDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .local_audio_duration)
    }

    /// Stable on-disk location for recorded voice-message clips. Lives
    /// in Caches so iOS can reclaim space under pressure, but is not
    /// the temp directory that gets wiped between launches. Both
    /// `VoiceService` (recording side) and the Codable decode path
    /// (reload side) resolve through this single helper so the
    /// filename round-trip lines up.
    static var voiceMessagesDirectory: URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("voice-messages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Attachment payload for `POST /api/chat` — base64 encoded.
struct ChatAttachment: Encodable {
    let content_type: String
    let data_base64: String
    let filename: String?
}

struct ChatUsage: Codable, Hashable {
    let messages_today: Int
    let tokens_in_today: Int
    let tokens_out_today: Int
    let cap: Int
    let remaining: Int
}

struct ChatHistory: Decodable {
    let messages: [ChatMessage]
    let usage: ChatUsage
}

struct ChatReply: Decodable {
    let reply: String
    let usage: ChatUsage
    /// Shopping mutations the backend asked us to execute locally —
    /// `add_shopping_item` / `complete_shopping_item` tool calls during
    /// this chat turn. We run them against `ShoppingListStore` on the
    /// device as soon as the response lands, instead of relying on the
    /// silent FCM push (which iOS throttles when the app is foreground
    /// and sometimes never delivers). Optional + defaulted to empty so
    /// older backend builds keep decoding.
    let shopping_actions: ShoppingActions?

    struct ShoppingActions: Decodable {
        let adds: [String]
        let completes: [String]
    }
}

struct FlightInsight: Codable, Identifiable, Hashable {
    var id: String {
        "\(airline ?? "")-\(flight_number ?? "")-\(departure_date_iso)"
    }
    let airline: String?
    let flight_number: String?
    let departure_date_iso: String
    let departure_airport: String?
    let arrival_airport: String?
    let passenger_name: String?
    let booking_reference: String?
    let source_email_id: String?

    var departureDate: Date? {
        // Try the strict formatters first (full ISO with timezone + fractional).
        if let d = ISO8601DateFormatter.limor.date(from: departure_date_iso) { return d }
        if let d = ISO8601DateFormatter().date(from: departure_date_iso) { return d }

        // Date + time WITHOUT a timezone (e.g. "2026-06-20T18:25:00"). The
        // backend prompt asks Haiku to omit the offset when the email doesn't
        // include one — interpret as the device's local time.
        let dt = DateFormatter()
        dt.locale = Locale(identifier: "en_US_POSIX")
        dt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = dt.date(from: departure_date_iso) { return d }
        dt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let d = dt.date(from: departure_date_iso) { return d }

        // Date only (e.g. "2026-06-20") — anchor to local midnight.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: departure_date_iso)
    }
}

struct Recommendation: Codable, Identifiable, Hashable {
    let id: String
    let kind: String          // movement | sleep | recovery | nutrition | calendar | mindfulness | celebration | general
    let title: String
    let body: String
    let cta: String?
    let priority: Int
    let generated_at: String?
}

struct InsightsBundle: Codable {
    let flights: [FlightInsight]
    let recommendations: [Recommendation]?
    let generated_at: String?
}

// MARK: - Recurring reminders (local-only, scheduled via UNUserNotificationCenter)

/// On-device recurring reminder — fires at the chosen hour/minute on the
/// selected weekdays, with the default iOS notification sound. Stored
/// locally in SharedStore; the backend chat-driven `Reminder` flow is
/// separate and untouched.
struct RecurringReminder: Codable, Identifiable, Hashable {
    let id: UUID
    var task: String
    /// Calendar weekday integers (1 = Sunday, 7 = Saturday) — matches
    /// `Calendar.component(.weekday, from:)`.
    var daysOfWeek: Set<Int>
    var hour: Int
    var minute: Int
    /// When true, all scheduled UNNotificationRequests for this reminder
    /// are cancelled — useful for vacations. Toggling back to false
    /// re-schedules.
    var paused: Bool
    /// Name of a `.caf` file bundled with the app, e.g. "bell.caf".
    /// `nil` = use the default iOS notification sound. Files live in
    /// `Limor Ai App/Sounds/` and are listed in `ReminderSound.allCases`.
    var soundName: String?
    let created_at: String

    init(task: String, daysOfWeek: Set<Int>, hour: Int, minute: Int, paused: Bool = false, soundName: String? = nil) {
        self.id = UUID()
        self.task = task
        self.daysOfWeek = daysOfWeek
        self.hour = hour
        self.minute = minute
        self.paused = paused
        self.soundName = soundName
        self.created_at = ISO8601DateFormatter.limor.string(from: Date())
    }

    // Decode older payloads that don't have `soundName` yet (default to
    // nil = system sound) so existing on-disk reminders keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.task = try c.decode(String.self, forKey: .task)
        self.daysOfWeek = try c.decode(Set<Int>.self, forKey: .daysOfWeek)
        self.hour = try c.decode(Int.self, forKey: .hour)
        self.minute = try c.decode(Int.self, forKey: .minute)
        self.paused = try c.decode(Bool.self, forKey: .paused)
        self.soundName = try c.decodeIfPresent(String.self, forKey: .soundName)
        self.created_at = try c.decode(String.self, forKey: .created_at)
    }

    private enum CodingKeys: String, CodingKey {
        case id, task, daysOfWeek, hour, minute, paused, soundName, created_at
    }
}

/// Bundled alarm sounds the user can pick for a recurring reminder.
/// Files live in `Limor Ai App/Sounds/`. Adding a new sound:
///   1. Drop a `<name>.caf` into the Sounds folder (max ~30s for iOS).
///   2. Add a case here with the file's raw name (no extension).
///   3. The editor UI auto-picks it up from `allCases`.
enum ReminderSound: String, CaseIterable, Identifiable {
    case bell, chime, digital, classic, morning

    var id: String { rawValue }
    var fileName: String { "\(rawValue).caf" }
    var displayName: String {
        switch self {
        case .bell:    return "פעמון"
        case .chime:   return "מנגינה"
        case .digital: return "דיגיטלי"
        case .classic: return "קלאסי"
        case .morning: return "בוקר"
        }
    }
}

// MARK: - Shopping list (local-only, persisted in SharedStore)

struct ShoppingItem: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var completed: Bool
    let added_at: String

    init(name: String, completed: Bool = false) {
        self.id = UUID()
        self.name = name
        self.completed = completed
        self.added_at = ISO8601DateFormatter.limor.string(from: Date())
    }
}

/// A single shopping "session" — the user adds items, checks them off,
/// and when everything's done the group is auto-archived (archived_at
/// gets a timestamp) and a fresh active group takes its place. The
/// archive lets the user look back at "what we bought last Tuesday".
struct ShoppingGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var items: [ShoppingItem]
    let created_at: String
    /// nil = still active; non-nil = archived (ISO timestamp).
    var archived_at: String?

    init(items: [ShoppingItem] = []) {
        self.id = UUID()
        self.items = items
        self.created_at = ISO8601DateFormatter.limor.string(from: Date())
        self.archived_at = nil
    }

    init(id: UUID, items: [ShoppingItem], created_at: String, archived_at: String?) {
        self.id = id
        self.items = items
        self.created_at = created_at
        self.archived_at = archived_at
    }

    /// True when there's at least one item and they're all completed —
    /// the trigger condition for the auto-archive flow.
    var isFullyCompleted: Bool {
        !items.isEmpty && items.allSatisfy(\.completed)
    }

    /// Display name for the archive list. Falls back to the group's
    /// creation date if no items.
    var summaryTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "d MMM yyyy"
        let date = ISO8601DateFormatter.limor.date(from: archived_at ?? created_at)
            ?? ISO8601DateFormatter().date(from: archived_at ?? created_at)
            ?? Date()
        return f.string(from: date)
    }
}

/// Wire shape for the `/api/shopping` GET/PUT — mirrors the backend
/// `ShoppingState` exactly. Same `ShoppingGroup` struct used locally
/// just rides along.
struct ShoppingStateDTO: Codable {
    let active: ShoppingGroup
    let archive: [ShoppingGroup]
}

// MARK: - Personal feed (user-chosen topics with web_search-powered updates)

struct FeedTopic: Codable, Identifiable, Hashable {
    let id: String
    let label: String
    let query: String
}

struct FeedSource: Codable, Hashable {
    let title: String
    let url: String
}

struct FeedItem: Codable, Identifiable, Hashable {
    var id: String { topic_id }
    let topic_id: String
    let topic_label: String
    let headline: String
    let body: String
    let sources: [FeedSource]
    let generated_at: String?
}

struct FeedBundle: Codable {
    let topics: [FeedTopic]
    let items: [FeedItem]
    let generated_at: String?
}

// MARK: - Calendar / Contacts (synced to backend)

struct CalendarEventDTO: Codable, Identifiable, Hashable {
    var id: String { event_id }
    let event_id: String
    let title: String
    let notes: String?
    let location: String?
    let start_at: String
    let end_at: String
    let is_all_day: Bool
    let calendar_name: String?
}

struct EmailDTO: Codable, Identifiable, Hashable {
    var id: String { message_id }
    let message_id: String
    let from: String
    let from_name: String?
    let subject: String
    let snippet: String
    let received_at: String        // ISO
    let is_unread: Bool
    let labels: [String]
    /// Plain-text body, only fetched for emails likely to be travel/booking
    /// related. nil for everything else (keeps payload + Firestore lean).
    let body_text: String?
    /// Provider thread/conversation id (Gmail threadId / Graph
    /// conversationId), so the backend action extractor can group a
    /// back-and-forth. `var … = nil` keeps the memberwise init backward
    /// compatible — call sites that don't set it still compile.
    var thread_id: String? = nil
    /// "in" = received by the user, "out" = sent by the user. Drives
    /// missed-follow-up detection ("they asked, I never replied").
    var direction: String? = nil
}

// MARK: - Executive email action report

/// How soon an action item should be handled. Mirrors the backend's
/// `EmailActionUrgency`.
enum EmailUrgency: String, Codable, Hashable {
    case critical, high, medium, low

    /// Map urgency → a sensible due date when turning an item into a reminder.
    /// critical = end of today, high = +24h, medium = +3 days, low = +7 days.
    func suggestedDueDate(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        switch self {
        case .critical:
            // 18:00 today, or +2h if it's already past 18:00.
            let six = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
            return six > now ? six : now.addingTimeInterval(2 * 3600)
        case .high:   return now.addingTimeInterval(24 * 3600)
        case .medium: return now.addingTimeInterval(3 * 24 * 3600)
        case .low:    return now.addingTimeInterval(7 * 24 * 3600)
        }
    }
}

/// One actionable email surfaced by the executive assistant.
struct EmailActionItem: Codable, Identifiable, Hashable {
    let id: String
    let sender_name: String
    let company: String?
    let subject: String
    let why: String
    let required_action: String
    let suggested_response: String?
    let urgency: EmailUrgency
    let importance: Int            // 1…10
    let source_email_id: String?
    let needs_review: Bool

    /// Stable identity for "handled" dismissal — survives the daily report
    /// regeneration (whose `id` is a fresh UUID each time). Prefers the
    /// source email id; falls back to subject + action content.
    var dismissKey: String {
        if let src = source_email_id, !src.isEmpty { return "email:\(src)" }
        return "content:\(subject)|\(required_action)"
    }
}

/// A thread where the user owes someone a follow-up.
struct EmailFollowUp: Codable, Identifiable, Hashable {
    let id: String
    let person: String
    let reason: String
    let source_email_id: String?

    /// Stable identity for "handled" dismissal (see `EmailActionItem.dismissKey`).
    var dismissKey: String {
        if let src = source_email_id, !src.isEmpty { return "followup:\(src)" }
        return "followup-content:\(person)|\(reason)"
    }
}

/// Daily executive email action report. Mirrors the backend `EmailActionReport`.
struct EmailActionReport: Codable, Hashable {
    let top_items: [EmailActionItem]
    let additional_items: [EmailActionItem]
    let follow_ups: [EmailFollowUp]
    let risks: [String]
    let todo: [String]
    let generated_at: String?

    var isEmpty: Bool {
        top_items.isEmpty && additional_items.isEmpty && follow_ups.isEmpty
            && risks.isEmpty && todo.isEmpty
    }

    static let empty = EmailActionReport(
        top_items: [], additional_items: [], follow_ups: [],
        risks: [], todo: [], generated_at: nil
    )
}

struct ContactDTO: Codable, Identifiable, Hashable {
    var id: String { identifier }
    let identifier: String
    let given_name: String?
    let family_name: String?
    let display_name: String
    let phones: [String]
    let emails: [String]
    let organization: String?
    /// Alternate forms of the name (Hebrew↔Latin transliterations, lowercased
    /// variants, given-name-only). Server-side fuzzy match also looks here so
    /// "עמית גולן" finds "Amit Golan".
    let aliases: [String]?
}

// MARK: - CRM (BituhOfir, gated)

/// Returned by `GET /api/crm/status`. `allowed` is the server-side
/// allowlist flag — if false, the iOS side should hide the CRM section
/// entirely. `connected` says whether a valid OTP session is stored on
/// the backend for this user.
struct CrmStatus: Codable, Hashable {
    let allowed: Bool
    let connected: Bool
    let phone_number: String?
    let connected_at: String?
}

// MARK: - Daily notifications

/// Each preset notification the user can configure. Server fires at the
/// scheduled local time (Asia/Jerusalem) and dedupes per day via
/// `last_sent_date`, which the iOS side just reads.
enum NotificationKind: String, Codable, Hashable, CaseIterable {
    case morning_brief
    case evening_recap
    case feed_digest
}

struct NotificationPref: Codable, Hashable, Identifiable {
    var id: String { kind.rawValue }
    let kind: NotificationKind
    var enabled: Bool
    var hour: Int
    var minute: Int
    let last_sent_date: String?
}

struct NotificationPrefsDoc: Codable {
    var master_enabled: Bool
    var prefs: [NotificationPref]
    /// Chosen notification sound — a bundled `.caf` filename (e.g. "bell.caf"),
    /// or nil for the default iOS sound. The backend mirrors it into reminder
    /// + daily push payloads; local notifications read it from SharedStore.
    var sound: String? = nil
}

// MARK: - User profile (what Limor knows about you)

/// One stable fact Limor remembers about the user — seeded by the
/// post-sign-up intro chat and extended at runtime via the LLM's
/// remember_about_user tool.
struct ProfileFact: Codable, Identifiable, Hashable {
    let id: String
    var label: String
    var value: String
    let source: Source
    let added_at: String

    enum Source: String, Codable, Hashable {
        case intro, chat, manual
    }
}

struct ProfileFactsResponse: Decodable {
    let facts: [ProfileFact]
    let intro_completed_at: String?
}

/// Payload for `POST /api/profile/intro` — server fills in id/added_at/source.
struct ProfileFactDraft: Encodable, Hashable {
    let label: String
    let value: String
}

/// Structured family/friend link tied to a specific iOS Contact. Picked
/// via `CNContactPickerViewController` in Settings → המשפחה שלי so Limor
/// can resolve things like "התקשר לבת זוגי" → the right contact name.
struct Relationship: Codable, Identifiable, Hashable {
    let id: String
    let relation: Kind
    let relation_label: String       // Hebrew label the user chose: "בת זוג", "אבא"
    let contact_identifier: String   // CNContact.identifier
    let contact_name: String
    let contact_phone: String?
    let added_at: String

    enum Kind: String, Codable, Hashable, CaseIterable {
        case spouse, child, parent, sibling, friend, other

        /// Suggested Hebrew label per kind — the user can override per row.
        var defaultLabel: String {
            switch self {
            case .spouse:  return "בן/בת זוג"
            case .child:   return "ילד/ה"
            case .parent:  return "הורה"
            case .sibling: return "אח/ות"
            case .friend:  return "חבר/ה"
            case .other:   return "אחר"
            }
        }

        var icon: String {
            switch self {
            case .spouse:  return "heart.fill"
            case .child:   return "figure.child"
            case .parent:  return "person.crop.circle.badge.checkmark"
            case .sibling: return "person.2.fill"
            case .friend:  return "person.fill"
            case .other:   return "person.circle"
            }
        }
    }
}

struct RelationshipsResponse: Decodable {
    let relationships: [Relationship]
}

extension ISO8601DateFormatter {
    static let limor: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
