import Foundation

enum DataSource: String, Codable, CaseIterable {
    case apple
    case google
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

struct ChatMessage: Decodable, Identifiable, Hashable {
    enum Role: String, Decodable, Hashable { case user, assistant }
    var id: String { "\(role.rawValue)-\(created_at)-\(content.hashValue)" }
    let role: Role
    let content: String
    let created_at: String
    /// Locally attached image data — only set on optimistic messages for preview
    /// in the bubble. Not decoded from server responses.
    var localAttachmentImageData: Data? = nil
    /// Locally attached document filename — same caveats.
    var localAttachmentFilename: String? = nil
    /// Locally recorded voice-message URL — only on the user's own optimistic
    /// bubble so the chat can render a play button + duration without
    /// round-tripping to the server. Not decoded from server responses.
    var localAudioURL: URL? = nil
    var localAudioDuration: TimeInterval? = nil

    private enum CodingKeys: String, CodingKey {
        case role, content, created_at
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
        self.localAudioURL = nil
        self.localAudioDuration = nil
    }
}

/// Attachment payload for `POST /api/chat` — base64 encoded.
struct ChatAttachment: Encodable {
    let content_type: String
    let data_base64: String
    let filename: String?
}

struct ChatUsage: Decodable, Hashable {
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

/// One real article on the topic-detail page. Distinct from `FeedItem`
/// (which is a synthesised summary across multiple sources) — each
/// `TopicArticle` is a single publisher's piece, with one source URL.
struct TopicArticle: Codable, Identifiable, Hashable {
    var id: String { source.url }
    let headline: String
    let summary: String
    let source: FeedSource
    let generated_at: String
}

struct TopicArticlesResponse: Decodable {
    let topic: FeedTopic
    let articles: [TopicArticle]
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
