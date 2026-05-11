import FirebaseAuth
import Foundation

/// HTTP client for the Cloud Run backend. Pulls a fresh Firebase ID token before
/// each request — Firebase caches the token internally, so the cost is just a
/// dictionary lookup unless it expired.
struct APIClient {
    static let shared = APIClient()

    private var baseURL: URL {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "LIMOR_API_BASE_URL") as? String,
           let url = URL(string: raw), !raw.isEmpty {
            return url
        }
        return URL(string: "http://localhost:8080")!
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Most endpoints come back in under a second, but a few hit Anthropic
        // with web_search and can take 30-60s (e.g. /api/feed/topic/:id/articles
        // runs Sonnet + up to 4 web searches). 90s leaves margin without
        // making genuine network failures feel hung forever.
        config.timeoutIntervalForRequest = 90
        return URLSession(configuration: config)
    }()

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Auth / profile

    func setDisplayName(_ displayName: String) async throws {
        struct Body: Encodable { let display_name: String }
        let _: EmptyResponse = try await post(
            "/auth/profile",
            body: Body(display_name: displayName)
        )
    }

    func updateProfile(displayName: String?, photoB64: String?) async throws {
        struct Body: Encodable {
            let display_name: String?
            let photo_b64: String?
        }
        let _: EmptyResponse = try await post(
            "/auth/profile",
            body: Body(display_name: displayName, photo_b64: photoB64)
        )
    }

    func getMe() async throws -> UserProfile {
        let env: UserProfileEnvelope = try await get("/auth/me")
        return env.user
    }

    // MARK: - Now

    func now(token: String, lat: Double?, lng: Double?) async throws -> NowResponse {
        var path = "/api/now"
        if let lat, let lng { path += "?lat=\(lat)&lng=\(lng)" }
        return try await get(path)
    }

    func weatherDetail(lat: Double, lng: Double) async throws -> WeatherDetail {
        try await get("/api/weather/detail?lat=\(lat)&lng=\(lng)")
    }

    // MARK: - Reminders

    func listReminders(token: String, status: String? = nil) async throws -> [Reminder] {
        var path = "/api/reminders"
        if let status { path += "?status=\(status)" }
        let env: RemindersEnvelope = try await get(path)
        return env.reminders
    }

    func createReminder(token: String, task: String, dueAt: Date) async throws -> Reminder {
        struct Body: Encodable { let task: String; let due_at: String }
        let body = Body(task: task, due_at: ISO8601DateFormatter.limor.string(from: dueAt))
        let env: ReminderEnvelope = try await post("/api/reminders", body: body)
        return env.reminder
    }

    func completeReminder(token: String, id: String) async throws -> Reminder {
        struct Empty: Encodable {}
        let env: ReminderEnvelope = try await post("/api/reminders/\(id)/complete", body: Empty())
        return env.reminder
    }

    func snoozeReminder(token: String, id: String, minutes: Int) async throws -> Reminder {
        struct Body: Encodable { let minutes: Int }
        let env: ReminderEnvelope = try await post("/api/reminders/\(id)/snooze", body: Body(minutes: minutes))
        return env.reminder
    }

    func deleteReminder(token: String, id: String) async throws {
        let _: EmptyResponse = try await deleteReq("/api/reminders/\(id)")
    }

    // MARK: - Devices / Push

    func registerFcmToken(token: String, deviceName: String?) async throws {
        struct Body: Encodable { let fcm_token: String; let device_name: String? }
        let _: EmptyResponse = try await post(
            "/api/devices/fcm",
            body: Body(fcm_token: token, device_name: deviceName)
        )
    }

    func unregisterFcmToken(token: String) async throws {
        struct Body: Encodable { let fcm_token: String }
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/devices/fcm"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(Body(fcm_token: token))
        let _: EmptyResponse = try await send(req)
    }

    // MARK: - Calendar / Contacts sync

    func syncCalendar(events: [CalendarEventDTO]) async throws {
        struct Body: Encodable { let events: [CalendarEventDTO] }
        let _: EmptyResponse = try await post("/api/calendar/sync", body: Body(events: events))
    }

    func syncContacts(contacts: [ContactDTO]) async throws {
        struct Body: Encodable { let contacts: [ContactDTO] }
        let _: EmptyResponse = try await post("/api/contacts/sync", body: Body(contacts: contacts))
    }

    func syncHealth(summary: HealthSummary) async throws {
        struct Body: Encodable { let summary: HealthSummary }
        let _: EmptyResponse = try await post("/api/health/sync", body: Body(summary: summary))
    }

    func syncEmail(emails: [EmailDTO]) async throws {
        struct Body: Encodable { let emails: [EmailDTO] }
        let _: EmptyResponse = try await post("/api/email/sync", body: Body(emails: emails))
    }

    // MARK: - Insights

    func getInsights() async throws -> InsightsBundle {
        try await get("/api/insights")
    }

    func refreshInsights() async throws -> InsightsBundle {
        struct Empty: Encodable {}
        return try await post("/api/insights/refresh", body: Empty())
    }

    // MARK: - Personal feed

    func getFeed() async throws -> FeedBundle {
        try await get("/api/feed")
    }

    func setFeedTopics(_ topics: [FeedTopic]) async throws -> FeedBundle {
        struct Body: Encodable { let topics: [FeedTopic] }
        struct Resp: Decodable { let topics: [FeedTopic] }
        let resp: Resp = try await post("/api/feed/topics", body: Body(topics: topics))
        // The server doesn't regenerate items here — return current cached
        // items merged with the new topic list so the caller can refresh
        // them in a separate call.
        let current = try await getFeed()
        return FeedBundle(topics: resp.topics, items: current.items, generated_at: current.generated_at)
    }

    func refreshFeed(force: Bool = false) async throws -> FeedBundle {
        struct Empty: Encodable {}
        let path = force ? "/api/feed/refresh?force=1" : "/api/feed/refresh"
        return try await post(path, body: Empty())
    }

    func topicArticles(topicId: String, force: Bool = false) async throws -> TopicArticlesResponse {
        let escaped = topicId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? topicId
        let path = "/api/feed/topic/\(escaped)/articles" + (force ? "?force=1" : "")
        return try await get(path)
    }

    func suggestFeedTopics(query: String) async throws -> [FeedTopic] {
        struct Suggestion: Decodable { let label: String; let query: String }
        struct Resp: Decodable { let suggestions: [Suggestion] }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let resp: Resp = try await get("/api/feed/suggest?q=\(escaped)")
        return resp.suggestions.map {
            FeedTopic(id: "suggest.\(UUID().uuidString)", label: $0.label, query: $0.query)
        }
    }

    // MARK: - CRM (BituhOfir, gated)

    func crmStatus() async throws -> CrmStatus {
        try await get("/api/crm/status")
    }

    func crmSendOtp(personId: String, phoneNumber: String) async throws {
        struct Body: Encodable { let person_id: String; let phone_number: String }
        let _: EmptyResponse = try await post(
            "/api/crm/sendotp",
            body: Body(person_id: personId, phone_number: phoneNumber)
        )
    }

    func crmVerifyOtp(personId: String, otpCode: String, phoneNumber: String) async throws {
        struct Body: Encodable {
            let person_id: String
            let otp_code: String
            let phone_number: String
        }
        let _: EmptyResponse = try await post(
            "/api/crm/verifyotp",
            body: Body(person_id: personId, otp_code: otpCode, phone_number: phoneNumber)
        )
    }

    func crmDisconnect() async throws {
        struct Empty: Encodable {}
        let _: EmptyResponse = try await post("/api/crm/disconnect", body: Empty())
    }

    // MARK: - Daily notifications

    func notificationPrefs() async throws -> NotificationPrefsDoc {
        try await get("/api/notifications/prefs")
    }

    func saveNotificationPrefs(_ prefs: NotificationPrefsDoc) async throws -> NotificationPrefsDoc {
        try await post("/api/notifications/prefs", body: prefs)
    }

    // MARK: - Profile (long-term memory)

    func profileFacts() async throws -> ProfileFactsResponse {
        try await get("/api/profile/facts")
    }

    func submitProfileIntro(facts: [ProfileFactDraft]) async throws -> ProfileFactsResponse {
        struct Body: Encodable { let facts: [ProfileFactDraft] }
        return try await post("/api/profile/intro", body: Body(facts: facts))
    }

    func addProfileFact(label: String, value: String) async throws -> ProfileFact {
        struct Body: Encodable { let label: String; let value: String }
        struct Resp: Decodable { let fact: ProfileFact }
        let r: Resp = try await post("/api/profile/facts", body: Body(label: label, value: value))
        return r.fact
    }

    func updateProfileFact(id: String, label: String, value: String) async throws {
        struct Body: Encodable { let label: String; let value: String }
        var req = URLRequest(url: resolveURL("/api/profile/facts/\(id)"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(Body(label: label, value: value))
        let _: EmptyResponse = try await send(req)
    }

    func deleteProfileFact(id: String) async throws {
        let _: EmptyResponse = try await deleteReq("/api/profile/facts/\(id)")
    }

    // MARK: - Relationships (linked contacts)

    func relationships() async throws -> [Relationship] {
        let r: RelationshipsResponse = try await get("/api/profile/relationships")
        return r.relationships
    }

    func addRelationship(
        relation: Relationship.Kind,
        relationLabel: String,
        contactIdentifier: String,
        contactName: String,
        contactPhone: String?
    ) async throws -> Relationship {
        struct Body: Encodable {
            let relation: String
            let relation_label: String
            let contact_identifier: String
            let contact_name: String
            let contact_phone: String?
        }
        struct Resp: Decodable { let relationship: Relationship }
        let r: Resp = try await post(
            "/api/profile/relationships",
            body: Body(
                relation: relation.rawValue,
                relation_label: relationLabel,
                contact_identifier: contactIdentifier,
                contact_name: contactName,
                contact_phone: contactPhone
            )
        )
        return r.relationship
    }

    func updateRelationship(
        id: String,
        relation: Relationship.Kind,
        relationLabel: String
    ) async throws {
        struct Body: Encodable { let relation: String; let relation_label: String }
        var req = URLRequest(url: resolveURL("/api/profile/relationships/\(id)"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(Body(relation: relation.rawValue, relation_label: relationLabel))
        let _: EmptyResponse = try await send(req)
    }

    func deleteRelationship(id: String) async throws {
        let _: EmptyResponse = try await deleteReq("/api/profile/relationships/\(id)")
    }

    // MARK: - Chat

    func chatHistory(token: String) async throws -> ChatHistory {
        try await get("/api/chat/history")
    }

    func sendChat(
        token: String,
        message: String,
        lat: Double?,
        lng: Double?,
        attachment: ChatAttachment? = nil
    ) async throws -> ChatReply {
        struct Body: Encodable {
            let message: String
            let user_lat: Double?
            let user_lng: Double?
            let attachment: ChatAttachment?
        }
        return try await post(
            "/api/chat",
            body: Body(message: message, user_lat: lat, user_lng: lng, attachment: attachment)
        )
    }

    // MARK: - HTTP plumbing

    /// Resolves a relative path (possibly with query string) against the base URL.
    /// `appendingPathComponent` is the wrong tool here because it percent-encodes
    /// the `?` of the query.
    private func resolveURL(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL) ?? baseURL.appendingPathComponent(path)
    }

    private func freshIdToken() async -> String? {
        guard let user = Auth.auth().currentUser else { return nil }
        return try? await withCheckedThrowingContinuation { continuation in
            user.getIDToken { token, error in
                if let token { continuation.resume(returning: token) }
                else { continuation.resume(throwing: error ?? URLError(.userAuthenticationRequired)) }
            }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: resolveURL(path))
        req.httpMethod = "GET"
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var req = URLRequest(url: resolveURL(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(body)
        return try await send(req)
    }

    private func deleteReq<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: resolveURL(path))
        req.httpMethod = "DELETE"
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? decoder.decode(ServerError.self, from: data))?.error ?? "http_\(http.statusCode)"
            throw APIError.server(status: http.statusCode, code: code)
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try decoder.decode(T.self, from: data)
    }
}

struct EmptyResponse: Decodable {}

enum APIError: LocalizedError {
    case invalidResponse
    case server(status: Int, code: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "תגובה לא תקינה מהשרת."
        case .server(let status, let code): return "שגיאה (\(status)): \(code)"
        }
    }
}

private struct ServerError: Decodable { let error: String }
