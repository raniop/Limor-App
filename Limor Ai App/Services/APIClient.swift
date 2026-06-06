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

    /// For the heaviest LLM endpoints — the executive email report runs
    /// Claude Sonnet over the whole inbox+sent window and can take well
    /// past 90s on the first (forced) generation. No data arrives until
    /// Anthropic finishes, so the per-request timeout never resets — hence
    /// a dedicated long session instead of the default 90s one.
    private let longSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        return URLSession(configuration: config)
    }()

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Auth / profile

    /// Forces a Firebase ID token fetch so the App Group bearer is populated
    /// for extensions even when no API call is in flight yet — e.g. right
    /// after sign-in. The actual write happens inside `freshIdToken` as a
    /// side effect; this exists just so callers don't need to throw the
    /// token away on the floor.
    @discardableResult
    func refreshSharedBearer() async -> Bool {
        await freshIdToken() != nil
    }

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

    /// Undo a previously completed reminder — used by the "החזר לפעיל"
    /// affordance in the reminders list. Mirrors `completeReminder` shape
    /// so call sites can reuse the same optimistic-update pattern.
    func reopenReminder(token: String, id: String) async throws -> Reminder {
        struct Empty: Encodable {}
        let env: ReminderEnvelope = try await post("/api/reminders/\(id)/reopen", body: Empty())
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

    /// Patch task text and/or due time on an existing reminder. Either
    /// argument can be nil — backend will only touch the fields the
    /// caller actually sent. Used by the iOS edit-reminder sheet.
    func updateReminder(id: String, task: String?, dueAt: Date?) async throws -> Reminder {
        struct Body: Encodable {
            let task: String?
            let due_at: String?
        }
        let body = Body(
            task: task,
            due_at: dueAt.map { ISO8601DateFormatter.limor.string(from: $0) }
        )
        var req = URLRequest(url: resolveURL("/api/reminders/\(id)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(body)
        let env: ReminderEnvelope = try await send(req)
        return env.reminder
    }

    // MARK: - Shopping list

    /// Fetch the user's full shopping state (active group + archived
    /// groups). Used on cold launch and on every scenePhase=.active.
    func getShoppingState() async throws -> ShoppingStateDTO {
        try await get("/api/shopping")
    }

    /// PUT the entire shopping state. The iOS client is the source of
    /// truth for ordering / IDs; server is dumb persistence + AI access.
    func putShoppingState(_ state: ShoppingStateDTO) async throws {
        let _: EmptyResponse = try await put("/api/shopping", body: state)
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

    // MARK: - Live Activity push tokens

    /// Register the APNs push token iOS minted for a Live Activity. The
    /// backend stores it per-reminder so the scheduler can send a direct
    /// `apns-push-type: liveactivity` push at due time, flipping the
    /// widget to its overdue look without needing to wake the app via
    /// the unreliable hybrid-FCM path.
    func registerLiveActivityToken(reminderId: String, pushToken: String) async throws {
        struct Body: Encodable {
            let reminder_id: String
            let push_token: String
        }
        let _: EmptyResponse = try await post(
            "/api/live-activities/register",
            body: Body(reminder_id: reminderId, push_token: pushToken)
        )
    }

    /// Drop the stored push token when iOS ends/dismisses the activity
    /// (or we end it ourselves after the reminder is overdue). Without
    /// this the backend would keep retrying APNs against dead tokens.
    func deregisterLiveActivityToken(reminderId: String) async throws {
        struct Body: Encodable { let reminder_id: String }
        var req = URLRequest(url: resolveURL("/api/live-activities/register"))
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(Body(reminder_id: reminderId))
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

    /// Pull one previously-synced email's full record (subject, snippet,
    /// body_text). Used by the flight-detail sheet to show the booking
    /// email behind the card. Returns `nil` when the message has aged out
    /// of the rolling per-user snapshot the backend keeps.
    func emailById(messageId: String) async throws -> EmailDTO? {
        struct Resp: Decodable { let email: EmailDTO }
        let escaped = messageId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? messageId
        do {
            let resp: Resp = try await get("/api/email/by-id?id=\(escaped)")
            return resp.email
        } catch let APIError.server(status, _) where status == 404 {
            return nil
        }
    }

    // MARK: - Insights

    func getInsights() async throws -> InsightsBundle {
        try await get("/api/insights")
    }

    func refreshInsights() async throws -> InsightsBundle {
        struct Empty: Encodable {}
        return try await post("/api/insights/refresh", body: Empty())
    }

    // MARK: - Executive email action report

    func getEmailActions() async throws -> EmailActionReport {
        try await get("/api/email/actions")
    }

    /// Regenerate the report. `force: true` bypasses the server's 24h cooldown
    /// (used for explicit pull-to-refresh); `false` lets the server no-op when
    /// the cached report is still fresh.
    func refreshEmailActions(force: Bool = false) async throws -> EmailActionReport {
        struct Empty: Encodable {}
        let path = force ? "/api/email/actions/refresh?force=1" : "/api/email/actions/refresh"
        // Sonnet over the whole inbox can run past the default 90s timeout —
        // use the long session so a real generation doesn't surface as an error.
        return try await post(path, body: Empty(), longRunning: true)
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

        // Race the Firebase callback against an 8-second timeout. On at least
        // one iPhone Air, the second chat send in a session hung indefinitely
        // inside `getIDToken` — Firebase appears to fire off a token-refresh
        // network call after the cached token rotates, and when that hangs
        // the completion handler is never invoked, the continuation never
        // resumes, and the entire send sits forever with `isSending=true`
        // (and from the user's point of view, the chat is frozen). Without
        // the safety net there is no way out short of killing the app.
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let lock = NSLock()
            var resolved = false

            user.getIDToken { token, _ in
                lock.lock()
                defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true
                // Mirror the freshest token into the App Group so the
                // Widget + Share extension can call the backend on their
                // own. Tokens are 1h-lived; the next freshIdToken call
                // overwrites this with a newer one before the old expires.
                if let token, !token.isEmpty {
                    SharedStore.bearer = token
                }
                cont.resume(returning: token)
            }

            Task {
                try? await Task.sleep(for: .seconds(8))
                lock.lock()
                defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true
                NSLog("[auth] Firebase getIDToken timed out after 8s — falling back to nil")
                cont.resume(returning: nil)
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

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, longRunning: Bool = false) async throws -> T {
        var req = URLRequest(url: resolveURL(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(body)
        return try await send(req, session: longRunning ? longSession : session)
    }

    private func deleteReq<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: resolveURL(path))
        req.httpMethod = "DELETE"
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req)
    }

    private func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var req = URLRequest(url: resolveURL(path))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer = await freshIdToken() {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try encoder.encode(body)
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest, session: URLSession? = nil) async throws -> T {
        let (data, response) = try await (session ?? self.session).data(for: req)
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
