import FirebaseCore
import Foundation
import GoogleSignIn
import PDFKit
import UIKit

/// REST client for Google Calendar + Gmail using the OAuth access token from
/// `GIDSignIn`. Each call refreshes the token if needed (via the SDK's helper)
/// before issuing the request.
@MainActor
struct GoogleAPIs {

    static let calendarReadOnlyScope = "https://www.googleapis.com/auth/calendar.readonly"
    static let gmailReadOnlyScope    = "https://www.googleapis.com/auth/gmail.readonly"

    enum APIError: LocalizedError {
        case notSignedInWithGoogle
        case googleConfigMissing
        case missingScope(String)
        case http(status: Int, body: String)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedInWithGoogle: return tr("לא הצלחתי לפתוח את חלון ההתחברות של Google.", "Couldn't open the Google sign-in window.")
            case .googleConfigMissing:   return tr("הגדרת Google חסרה. ודא שיש GoogleService-Info.plist.", "Google configuration is missing. Make sure GoogleService-Info.plist exists.")
            case .missingScope(let s):   return tr("Google לא אישר את ההרשאה הנדרשת (\(s)).", "Google didn't grant the required permission (\(s)).")
            case .http(let status, _):   return tr("Google API החזיר \(status).", "The Google API returned \(status).")
            case .decodingFailed(let s): return tr("כשל בפענוח תשובה: \(s)", "Failed to decode the response: \(s)")
            }
        }
    }

    // MARK: - Scope management

    static func grantedScopes() -> Set<String> {
        Set(GIDSignIn.sharedInstance.currentUser?.grantedScopes ?? [])
    }

    /// The connected Google account address, e.g. "rani@gmail.com". Used to
    /// tag synced emails so the action report can attribute each item.
    static func accountEmail() -> String? {
        GIDSignIn.sharedInstance.currentUser?.profile?.email
    }

    /// Throw if any of the requested scopes is missing — but never present
    /// UI. Use this from background sync paths so a revoked scope doesn't
    /// blast the user with a Google sign-in sheet every time the app
    /// foregrounds. The interactive paths (Settings toggle, onboarding
    /// "Connect Gmail" button) should keep calling `ensureScopes` which
    /// IS allowed to prompt.
    static func requireScopes(_ scopes: [String]) throws {
        let granted = grantedScopes()
        for s in scopes where !granted.contains(s) {
            throw APIError.missingScope(s)
        }
    }

    static func ensureScopes(_ scopes: [String]) async throws {
        // GIDGoogleUser.addScopes internally goes through GIDSignIn's
        // signInWithOptions: which crashes hard ("No active configuration.
        // Make sure GIDClientID is set in Info.plist.") if
        // GIDSignIn.sharedInstance.configuration ever ended up nil.
        // Defensively re-seed it before either path. (Belt-and-suspenders
        // — Info.plist now also has GIDClientID as a static fallback.)
        if GIDSignIn.sharedInstance.configuration == nil,
           let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }

        // Case 1: no Google session at all (user signed in with Apple) — kick off
        // a fresh Google sign-in that already requests the desired scopes.
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            try await startGoogleSignIn(scopes: scopes)
            return
        }

        // Case 2: Google session exists but missing some scopes — incremental.
        let granted = grantedScopes()
        let missing = scopes.filter { !granted.contains($0) }
        guard !missing.isEmpty else { return }

        guard let presenting = topViewController() else {
            throw APIError.notSignedInWithGoogle
        }
        let result = try await user.addScopes(missing, presenting: presenting)
        let nowGranted = Set(result.user.grantedScopes ?? [])
        for s in missing where !nowGranted.contains(s) {
            throw APIError.missingScope(s)
        }
    }

    /// Starts a fresh Google OAuth flow with `additionalScopes` already requested.
    /// Used when the user is signed into Firebase via Apple but wants to read
    /// Gmail / Google Calendar — we connect a Google account on the side just
    /// for API access (no link to Firebase auth).
    private static func startGoogleSignIn(scopes: [String]) async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw APIError.googleConfigMissing
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        guard let presenting = topViewController() else {
            throw APIError.notSignedInWithGoogle
        }

        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenting,
            hint: nil,
            additionalScopes: scopes
        )
        let granted = Set(result.user.grantedScopes ?? [])
        for s in scopes where !granted.contains(s) {
            throw APIError.missingScope(s)
        }
    }

    // MARK: - Calendar

    static func fetchCalendarEvents(daysAhead: Int = 60) async throws -> [CalendarEventDTO] {
        // requireScopes (no prompt) — sync paths must fail silently when
        // the scope is missing rather than bouncing the user to Google.
        try requireScopes([calendarReadOnlyScope])

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) ?? now
        let formatter = ISO8601DateFormatter.limor

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            .init(name: "timeMin", value: formatter.string(from: now)),
            .init(name: "timeMax", value: formatter.string(from: end)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "200"),
        ]

        let data = try await get(components.url!)
        let response = try decode(GoogleCalendarListResponse.self, from: data)
        return response.items.compactMap { item in
            guard let start = item.start.normalized, let end = item.end.normalized else { return nil }
            return CalendarEventDTO(
                event_id: item.id,
                title: item.summary ?? tr("(ללא כותרת)", "(No title)"),
                notes: item.description,
                location: item.location,
                start_at: formatter.string(from: start.date),
                end_at: formatter.string(from: end.date),
                is_all_day: start.isAllDay,
                calendar_name: "Google"
            )
        }
    }

    // MARK: - Gmail

    /// Recent messages from the user's mailbox — last `daysBack` days, up to
    /// `limit`. Excludes promotions/social so we don't drown Claude in noise,
    /// but keeps archived emails (booking confirmations are often archived).
    /// For emails matching travel keywords we ALSO fetch the full body so the
    /// insights extractor has more than a 150-char snippet to work with.
    static func fetchRecentEmails(daysBack: Int = 60, limit: Int = 60) async throws -> [EmailDTO] {
        // requireScopes (no prompt) — sync paths must fail silently when
        // the scope is missing rather than bouncing the user to Google.
        try requireScopes([gmailReadOnlyScope])

        // Wide search: include archived emails (no `in:inbox`), exclude obvious noise.
        let query = "newer_than:\(daysBack)d -category:promotions -category:social"
        var listComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        listComponents.queryItems = [
            .init(name: "q", value: query),
            .init(name: "maxResults", value: String(limit)),
        ]
        let listData = try await get(listComponents.url!)
        let listResponse = try decode(GmailListResponse.self, from: listData)
        guard let messages = listResponse.messages, !messages.isEmpty else { return [] }

        // Step 1: parallel metadata fetch. We use a non-throwing TaskGroup and
        // swallow per-fetch errors — a single transient network error must not
        // truncate the whole batch (which would cause the insights snapshot to
        // get overwritten with stale data).
        var out: [EmailDTO] = []
        await withTaskGroup(of: EmailDTO?.self) { group in
            for ref in messages {
                group.addTask {
                    do { return try await fetchEmailMetadata(id: ref.id) }
                    catch { return nil }
                }
            }
            for await dto in group {
                if let dto { out.append(dto) }
            }
        }

        // Newest first.
        out.sort { $0.received_at > $1.received_at }

        // Step 2: fetch full bodies. The travel/flight extractor needs them
        // for booking emails, the receipt extractor needs the charged amount
        // (snippets often cut it off), and the executive action extractor
        // needs the actual thread content (snippets lose the ask). So we pull
        // bodies for every travel-likely email, the newest receipt-likely
        // emails, PLUS the most-recent N messages (covers active threads,
        // inbound + sent), deduped and capped.
        let travelIndices = out.indices.filter { isTravelLikely(out[$0]) }
        let receiptIndices = Array(out.indices.filter { isReceiptLikely(out[$0]) }.prefix(40))
        let recentIndices = Array(out.indices.prefix(30))   // out is newest-first
        var bodyIndices: [Int] = []
        var seenIdx = Set<Int>()
        for idx in travelIndices + receiptIndices + recentIndices where seenIdx.insert(idx).inserted {
            bodyIndices.append(idx)
        }

        await withTaskGroup(of: (Int, String?).self) { group in
            for idx in bodyIndices {
                let id = out[idx].message_id
                group.addTask {
                    let body = try? await fetchEmailFullBody(id: id)
                    return (idx, body)
                }
            }
            for await (idx, body) in group {
                guard let body else { continue }
                let trimmed = String(body.prefix(8000))   // keep DB write small
                out[idx] = out[idx].withBody(trimmed)
            }
        }

        return out
    }

    /// Heuristic — same spirit as the backend keyword check, kept light here.
    private static func isTravelLikely(_ e: EmailDTO) -> Bool {
        let h = "\(e.subject) \(e.from_name ?? "") \(e.from) \(e.snippet)".lowercased()
        let keys = [
            "flight", "ticket", "boarding", "itinerary", "reservation",
            "e-ticket", "etix", "pnr", "confirmation",
            "טיסה", "כרטיס", "אישור הזמנה",
            "airways", "airlines", "bluebird", "blue bird",
            "el al", "אל על", "easyjet", "ryanair", "wizz",
            "booking.com", "trip.com", "kiwi", "issta",
            "israir", "ישראייר", "arkia", "ארקיע", "nextravel", "e-ticket", "eticket",
        ]
        return keys.contains { h.contains($0) }
    }

    /// Heuristic mirror of the backend's receipt prefilter — only decides
    /// which emails get a full-body fetch; Claude does the real extraction.
    private static func isReceiptLikely(_ e: EmailDTO) -> Bool {
        let h = "\(e.subject) \(e.from_name ?? "") \(e.from) \(e.snippet)".lowercased()
        let keys = [
            "receipt", "invoice", "payment", "paid", "charged",
            "your order", "order confirmation", "purchase", "transaction", "billing",
            "קבלה", "חשבונית", "תשלום", "חיוב", "חויב", "שילמת",
            "רכישה", "הזמנתך", "אישור תשלום", "מנוי",
        ]
        return keys.contains { h.contains($0) }
    }

    /// Pull the full message in `format=full` and decode the text part. Flight
    /// confirmations (e.g. Israir/Nextravel e-tickets) often carry the actual
    /// flight details ONLY in an attached PDF, so we also extract text from any
    /// PDF attachment and append it — otherwise Limor's extractor sees a body
    /// with no flight in it.
    private static func fetchEmailFullBody(id: String) async throws -> String? {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [.init(name: "format", value: "full")]
        let data = try await get(components.url!)
        let msg = try decode(GmailFullMessage.self, from: data)

        let plain = extractPlainText(from: msg.payload)
        let pdfText = await extractPdfAttachmentsText(messageId: id, payload: msg.payload)

        let combined = [plain, pdfText].compactMap { $0 }.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }

    /// Walk the payload for PDF attachments, fetch each, and pull its text via
    /// PDFKit. Capped so a huge boarding-pass bundle can't blow up the payload.
    private static func extractPdfAttachmentsText(messageId: String, payload: GmailPayloadFull?) async -> String? {
        guard let payload else { return nil }
        var ids: [String] = []
        func walk(_ p: GmailPayloadFull) {
            let isPdf = (p.mimeType == "application/pdf")
                || ((p.filename ?? "").lowercased().hasSuffix(".pdf"))
            if isPdf, let aid = p.body?.attachmentId { ids.append(aid) }
            p.parts?.forEach(walk)
        }
        walk(payload)
        guard !ids.isEmpty else { return nil }

        var chunks: [String] = []
        for aid in ids.prefix(4) {
            guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/attachments/\(aid)"),
                  let data = try? await get(url),
                  let att = try? decode(GmailAttachment.self, from: data),
                  let b64 = att.data,
                  let pdfData = decodeBase64UrlData(b64),
                  let doc = PDFDocument(data: pdfData) else { continue }
            var text = ""
            for i in 0..<doc.pageCount {
                if let s = doc.page(at: i)?.string { text += s + "\n" }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chunks.append(String(trimmed.prefix(8000))) }
        }
        return chunks.isEmpty ? nil : chunks.joined(separator: "\n\n")
    }

    private static func extractPlainText(from payload: GmailPayloadFull?) -> String? {
        guard let payload else { return nil }
        // Direct text body
        if payload.mimeType == "text/plain", let raw = payload.body?.data,
           let decoded = decodeBase64Url(raw) {
            return decoded
        }
        // Multipart — prefer text/plain, fall back to stripped text/html, recurse for nested.
        if let parts = payload.parts {
            for p in parts where p.mimeType == "text/plain" {
                if let raw = p.body?.data, let decoded = decodeBase64Url(raw) {
                    return decoded
                }
            }
            for p in parts where p.mimeType == "text/html" {
                if let raw = p.body?.data, let decoded = decodeBase64Url(raw) {
                    return stripHTML(decoded)
                }
            }
            for p in parts where (p.mimeType ?? "").hasPrefix("multipart/") {
                if let nested = extractPlainText(from: p) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func decodeBase64Url(_ s: String) -> String? {
        guard let data = decodeBase64UrlData(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Raw bytes from a base64url string (Gmail attachment payloads). Tolerates
    /// missing padding and large data (PDFs).
    private static func decodeBase64UrlData(_ s: String) -> Data? {
        var base64 = s.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fetchEmailMetadata(id: String) async throws -> EmailDTO? {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "metadataHeaders", value: "Date"),
        ]
        let data = try await get(components.url!)
        let msg = try decode(GmailMessage.self, from: data)
        let headers = msg.payload?.headers ?? []
        let from = headers.first { $0.name.lowercased() == "from" }?.value ?? ""
        let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? tr("(ללא נושא)", "(No subject)")
        let dateHeader = headers.first { $0.name.lowercased() == "date" }?.value ?? ""

        let received: Date
        if let internalDate = Int(msg.internalDate ?? "") {
            received = Date(timeIntervalSince1970: TimeInterval(internalDate) / 1000)
        } else if let parsed = parseRFC2822(dateHeader) {
            received = parsed
        } else {
            received = Date()
        }

        let (fromName, fromEmail) = parseFromHeader(from)

        let labelIds = msg.labelIds ?? []
        return EmailDTO(
            message_id: msg.id,
            from: fromEmail,
            from_name: fromName,
            subject: subject,
            snippet: msg.snippet ?? "",
            received_at: ISO8601DateFormatter.limor.string(from: received),
            is_unread: labelIds.contains("UNREAD"),
            labels: labelIds,
            body_text: nil,
            thread_id: msg.threadId,
            // Gmail tags the user's own sent messages with the SENT label —
            // free direction detection, no need for the account address.
            direction: labelIds.contains("SENT") ? "out" : "in"
        )
    }

    // MARK: - HTTP

    private static func get(_ url: URL) async throws -> Data {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw APIError.notSignedInWithGoogle
        }
        // Refresh access token if needed.
        let _ = try await user.refreshTokensIfNeeded()
        let token = GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString ?? ""

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: 0, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: body)
        }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decodingFailed(String(describing: error)) }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard let root = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windowScene?.windows.first?.rootViewController else { return nil }
        var current = root
        while let presented = current.presentedViewController { current = presented }
        return current
    }

    // MARK: - Helpers

    private static func parseFromHeader(_ raw: String) -> (name: String?, email: String) {
        // "Display Name <a@b.com>" → ("Display Name", "a@b.com")
        if let lt = raw.firstIndex(of: "<"), let gt = raw.firstIndex(of: ">"), lt < gt {
            let name = raw[..<lt].trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            let email = String(raw[raw.index(after: lt)..<gt])
            return (name.isEmpty ? nil : name, email)
        }
        return (nil, raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseRFC2822(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.date(from: s)
    }
}

// MARK: - Google Calendar response shapes

private struct GoogleCalendarListResponse: Decodable { let items: [GoogleCalendarItem] }
private struct GoogleCalendarItem: Decodable {
    let id: String
    let summary: String?
    let description: String?
    let location: String?
    let start: GoogleCalendarTime
    let end: GoogleCalendarTime
}
private struct GoogleCalendarTime: Decodable {
    let dateTime: String?
    let date: String?

    var normalized: (date: Date, isAllDay: Bool)? {
        if let dt = dateTime, let parsed = ISO8601DateFormatter.limor.date(from: dt) ?? ISO8601DateFormatter().date(from: dt) {
            return (parsed, false)
        }
        if let d = date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone.current
            if let parsed = f.date(from: d) { return (parsed, true) }
        }
        return nil
    }
}

// MARK: - Gmail response shapes

private struct GmailListResponse: Decodable {
    let messages: [GmailMessageRef]?
}
private struct GmailMessageRef: Decodable { let id: String }

private struct GmailMessage: Decodable {
    let id: String
    let threadId: String?
    let snippet: String?
    let internalDate: String?
    let labelIds: [String]?
    let payload: GmailPayload?
}
private struct GmailPayload: Decodable {
    let headers: [GmailHeader]?
}
private struct GmailHeader: Decodable {
    let name: String
    let value: String
}

// Full-format response (`format=full`) — has body data + nested parts.
private struct GmailFullMessage: Decodable {
    let payload: GmailPayloadFull?
}
struct GmailPayloadFull: Decodable {
    let mimeType: String?
    let filename: String?
    let body: GmailBody?
    let parts: [GmailPayloadFull]?
}
struct GmailBody: Decodable {
    let data: String?
    let size: Int?
    let attachmentId: String?
}
private struct GmailAttachment: Decodable {
    let data: String?   // base64url
}

// MARK: - EmailDTO body builder

private extension EmailDTO {
    func withBody(_ body: String) -> EmailDTO {
        EmailDTO(
            message_id: message_id,
            from: from,
            from_name: from_name,
            subject: subject,
            snippet: snippet,
            received_at: received_at,
            is_unread: is_unread,
            labels: labels,
            body_text: body,
            thread_id: thread_id,
            direction: direction
        )
    }
}
