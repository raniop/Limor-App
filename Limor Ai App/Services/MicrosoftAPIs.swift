import Foundation
import MSAL
import UIKit

/// REST client for Microsoft 365 / Outlook — mail + calendar via Microsoft
/// Graph. Mirrors `GoogleAPIs` so `SyncManager` can dispatch on the same
/// `DataSource` enum. Auth is handled by MSAL (Microsoft Authentication
/// Library), which caches the account + refresh token in the keychain — no
/// explicit storage code needed.
///
/// Setup checklist (one-time, outside this file):
///   1. Register a public client app in Azure AD with redirect URI
///      `msauth.com.rani.Limor-Ai-App://auth` and Graph delegated permissions
///      `Mail.Read`, `Calendars.Read`, `offline_access`, `User.Read`.
///   2. Paste the Application (client) ID into `MicrosoftAPIs.clientID` below.
///   3. Info.plist already declares the `msauth.com.rani.Limor-Ai-App` URL
///      scheme and `msauthv2` / `msauthv3` in LSApplicationQueriesSchemes.
@MainActor
struct MicrosoftAPIs {

    /// Paste your Azure AD App Registration's "Application (client) ID" here.
    /// Until this is filled in, all Outlook flows will throw `notConfigured`.
    static let clientID = "5710d50f-d0d0-4f49-8067-58537d200eb6"

    /// `common` = sign in with both personal (outlook.com / hotmail) and work
    /// (Office 365) Microsoft accounts. Matches the multi-tenant option chosen
    /// during Azure registration.
    static let authority = "https://login.microsoftonline.com/common"

    /// Must match the redirect URI registered in Azure AD AND the URL scheme
    /// declared in Info.plist (CFBundleURLSchemes).
    static let redirectURI = "msauth.com.rani.Limor-Ai-App://auth"

    static let mailReadScope     = "Mail.Read"
    static let calendarReadScope = "Calendars.Read"

    enum APIError: LocalizedError {
        case notConfigured
        case notSignedIn
        case missingScope(String)
        case http(status: Int, body: String)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:         return "החיבור ל-Outlook לא הוגדר. חסר Client ID."
            case .notSignedIn:           return "לא הצלחתי לפתוח את חלון ההתחברות של Microsoft."
            case .missingScope(let s):   return "Microsoft לא אישר את ההרשאה הנדרשת (\(s))."
            case .http(let status, _):   return "Microsoft Graph החזיר \(status)."
            case .decodingFailed(let s): return "כשל בפענוח תשובה: \(s)"
            }
        }
    }

    // MARK: - MSAL application singleton

    private static var _application: MSALPublicClientApplication?

    private static func application() throws -> MSALPublicClientApplication {
        if let cached = _application { return cached }
        guard clientID != "<PASTE_AZURE_CLIENT_ID_HERE>", !clientID.isEmpty else {
            throw APIError.notConfigured
        }
        guard let authorityURL = URL(string: authority) else {
            throw APIError.notConfigured
        }
        let msAuthority = try MSALAADAuthority(url: authorityURL)
        let config = MSALPublicClientApplicationConfig(
            clientId: clientID,
            redirectUri: redirectURI,
            authority: msAuthority
        )
        let app = try MSALPublicClientApplication(configuration: config)
        _application = app
        return app
    }

    /// Best-effort init at cold-launch so MSAL's URL handler is ready and the
    /// cached account (if any) is loaded. Safe to call without a Client ID —
    /// we just no-op and the UI will fail later with `notConfigured` when the
    /// user tries to connect.
    static func bootstrap() {
        _ = try? application()
    }

    // MARK: - Scope tracking
    //
    // Background sync paths must fail silently if a scope hasn't been granted
    // — same contract as `GoogleAPIs.requireScopes`. MSAL doesn't expose a
    // "list of consented scopes" the way GIDSignIn does, so we stash them in
    // App Group UserDefaults each time interactive consent succeeds. Cleared
    // on sign-out.

    private static let grantedScopesKey = "limor.ms.grantedScopes"

    private static var groupDefaults: UserDefaults {
        UserDefaults(suiteName: "group.com.rani.Limor-Ai-App") ?? .standard
    }

    static func grantedScopes() -> Set<String> {
        Set(groupDefaults.stringArray(forKey: grantedScopesKey) ?? [])
    }

    private static func rememberGrantedScopes(_ scopes: [String]) {
        var s = grantedScopes()
        for scope in scopes { s.insert(scope) }
        groupDefaults.set(Array(s), forKey: grantedScopesKey)
    }

    private static func clearGrantedScopes() {
        groupDefaults.removeObject(forKey: grantedScopesKey)
    }

    static func isSignedIn() -> Bool {
        guard let app = try? application() else { return false }
        return ((try? app.allAccounts())?.isEmpty == false)
    }

    /// Throw if any of the requested scopes is missing — but never present
    /// UI. Use this from background sync paths so a revoked scope doesn't
    /// blast the user with a Microsoft sign-in sheet every time the app
    /// foregrounds.
    static func requireScopes(_ scopes: [String]) throws {
        guard isSignedIn() else { throw APIError.notSignedIn }
        let granted = grantedScopes()
        for s in scopes where !granted.contains(s) {
            throw APIError.missingScope(s)
        }
    }

    /// Interactive path: silent first, fallback to interactive consent if
    /// the scope isn't cached or the cached token can't be refreshed.
    static func ensureScopes(_ scopes: [String]) async throws {
        let app = try application()
        let accounts = (try? app.allAccounts()) ?? []

        if let account = accounts.first {
            do {
                let params = MSALSilentTokenParameters(scopes: scopes, account: account)
                let result = try await app.acquireTokenSilent(with: params)
                rememberGrantedScopes(result.scopes + scopes)
                return
            } catch let nsErr as NSError where isInteractionRequired(nsErr) {
                // Fall through to interactive.
            }
        }

        try await runInteractive(scopes: scopes)
    }

    private static func runInteractive(scopes: [String]) async throws {
        let app = try application()
        guard let presenting = topViewController() else {
            throw APIError.notSignedIn
        }
        let webParams = MSALWebviewParameters(authPresentationViewController: presenting)
        let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webParams)
        do {
            let result = try await app.acquireToken(with: params)
            rememberGrantedScopes(result.scopes + scopes)
        } catch {
            // MSAL's `localizedDescription` is just "The operation couldn't
            // be completed. (MSALErrorDomain error -50000.)" — useless for
            // diagnosing config issues. Dig into userInfo and surface a real
            // message so the user (and the console) can tell whether it's a
            // bad redirect URI, missing scope consent, network problem, etc.
            logMSALError(error, where: "interactive")
            throw NSError(
                domain: "limor.microsoft",
                code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: friendlyMSALMessage(error)]
            )
        }
    }

    private static func logMSALError(_ error: Error, where context: String) {
        let ns = error as NSError
        print("[microsoft] \(context) failed — domain=\(ns.domain) code=\(ns.code)")
        for (k, v) in ns.userInfo {
            print("    \(k) = \(v)")
        }
    }

    private static func friendlyMSALMessage(_ error: Error) -> String {
        let ns = error as NSError
        var bits: [String] = []
        if let desc = ns.userInfo["MSALErrorDescriptionKey"] as? String, !desc.isEmpty {
            bits.append(desc)
        } else if let desc = ns.userInfo[NSLocalizedDescriptionKey] as? String, !desc.isEmpty {
            bits.append(desc)
        }
        if let oauth = ns.userInfo["MSALOAuthErrorKey"] as? String, !oauth.isEmpty {
            bits.append("oauth=\(oauth)")
        }
        if let internalCode = ns.userInfo["MSALInternalErrorCodeKey"] as? Int {
            bits.append("internal=\(internalCode)")
        }
        bits.append("(code \(ns.code))")
        return "Microsoft: " + bits.joined(separator: " — ")
    }

    static func signOut() {
        guard let app = try? application() else { return }
        let accounts = (try? app.allAccounts()) ?? []
        for acc in accounts {
            try? app.remove(acc)
        }
        clearGrantedScopes()
    }

    // MARK: - Calendar

    static func fetchCalendarEvents(daysAhead: Int = 60) async throws -> [CalendarEventDTO] {
        try requireScopes([calendarReadScope])

        let formatter = ISO8601DateFormatter.limor
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now) ?? now

        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarView")!
        components.queryItems = [
            .init(name: "startDateTime", value: formatter.string(from: now)),
            .init(name: "endDateTime",   value: formatter.string(from: end)),
            .init(name: "$top",          value: "200"),
            .init(name: "$orderby",      value: "start/dateTime"),
            .init(name: "$select",       value: "id,subject,bodyPreview,location,start,end,isAllDay"),
        ]

        let data = try await get(components.url!, scopes: [calendarReadScope], preferUTC: true)
        let response = try decode(GraphCalendarResponse.self, from: data)

        return response.value.compactMap { item in
            guard let start = parseGraphDateTime(item.start),
                  let endDate = parseGraphDateTime(item.end) else { return nil }
            return CalendarEventDTO(
                event_id: item.id,
                title: item.subject ?? "(ללא כותרת)",
                notes: item.bodyPreview,
                location: item.location?.displayName,
                start_at: formatter.string(from: start),
                end_at: formatter.string(from: endDate),
                is_all_day: item.isAllDay ?? false,
                calendar_name: "Outlook"
            )
        }
    }

    // MARK: - Mail

    /// Same shape as `GoogleAPIs.fetchRecentEmails` — recent inbox messages,
    /// with full bodies fetched for the few that look travel-related.
    static func fetchRecentEmails(daysBack: Int = 60, limit: Int = 60) async throws -> [EmailDTO] {
        try requireScopes([mailReadScope])

        let formatter = ISO8601DateFormatter.limor
        let sinceDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let filterDate = formatter.string(from: sinceDate)

        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
        components.queryItems = [
            .init(name: "$top",     value: String(limit)),
            .init(name: "$orderby", value: "receivedDateTime desc"),
            .init(name: "$filter",  value: "receivedDateTime ge \(filterDate)"),
            .init(name: "$select",  value: "id,subject,from,receivedDateTime,bodyPreview,isRead,categories,internetMessageId"),
        ]
        let data = try await get(components.url!, scopes: [mailReadScope])
        let response = try decode(GraphMailListResponse.self, from: data)

        var out: [EmailDTO] = response.value.map { msg in
            let fromName  = msg.from?.emailAddress?.name
            let fromEmail = msg.from?.emailAddress?.address ?? ""
            return EmailDTO(
                message_id: msg.id,
                from: fromEmail,
                from_name: (fromName?.isEmpty == false) ? fromName : nil,
                subject: msg.subject ?? "(ללא נושא)",
                snippet: msg.bodyPreview ?? "",
                received_at: msg.receivedDateTime ?? formatter.string(from: Date()),
                is_unread: !(msg.isRead ?? true),
                labels: msg.categories ?? [],
                body_text: nil
            )
        }

        // Newest first (server already sorts, but be defensive).
        out.sort { $0.received_at > $1.received_at }

        // Augment travel-likely emails with full body.
        let travelIndices = out.indices
            .filter { isTravelLikely(out[$0]) }
            .prefix(8)

        await withTaskGroup(of: (Int, String?).self) { group in
            for idx in travelIndices {
                let id = out[idx].message_id
                group.addTask {
                    let body = try? await fetchEmailFullBody(id: id)
                    return (idx, body)
                }
            }
            for await (idx, body) in group {
                guard let body else { continue }
                let trimmed = String(body.prefix(8000))
                out[idx] = out[idx].withBody(trimmed)
            }
        }

        return out
    }

    private static func fetchEmailFullBody(id: String) async throws -> String? {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages/\(id)")!
        components.queryItems = [.init(name: "$select", value: "body")]
        let data = try await get(components.url!, scopes: [mailReadScope])
        let msg = try decode(GraphMailBodyResponse.self, from: data)
        guard let body = msg.body, let content = body.content, !content.isEmpty else { return nil }
        if (body.contentType ?? "").lowercased() == "html" {
            return stripHTML(content)
        }
        return content
    }

    private static func isTravelLikely(_ e: EmailDTO) -> Bool {
        let h = "\(e.subject) \(e.from_name ?? "") \(e.from) \(e.snippet)".lowercased()
        let keys = [
            "flight", "ticket", "boarding", "itinerary", "reservation",
            "e-ticket", "etix", "pnr", "confirmation",
            "טיסה", "כרטיס", "אישור הזמנה",
            "airways", "airlines", "bluebird", "blue bird",
            "el al", "אל על", "easyjet", "ryanair", "wizz",
            "booking.com", "trip.com", "kiwi", "issta",
        ]
        return keys.contains { h.contains($0) }
    }

    // MARK: - HTTP

    private static func token(forScopes scopes: [String]) async throws -> String {
        let app = try application()
        let accounts = (try? app.allAccounts()) ?? []
        guard let account = accounts.first else { throw APIError.notSignedIn }
        let params = MSALSilentTokenParameters(scopes: scopes, account: account)
        let result = try await app.acquireTokenSilent(with: params)
        return result.accessToken
    }

    private static func get(_ url: URL, scopes: [String], preferUTC: Bool = false) async throws -> Data {
        let bearer = try await token(forScopes: scopes)
        var req = URLRequest(url: url)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if preferUTC {
            // Graph returns event times in whatever zone the mailbox is set to
            // unless we explicitly opt into UTC — without this, the ISO strings
            // we emit downstream won't round-trip correctly.
            req.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        }

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

    // MARK: - Helpers

    private static func isInteractionRequired(_ err: NSError) -> Bool {
        guard err.domain == MSALErrorDomain else { return false }
        return err.code == MSALError.interactionRequired.rawValue
    }

    private static func parseGraphDateTime(_ field: GraphDateTime?) -> Date? {
        guard let field, let raw = field.dateTime else { return nil }
        // Graph returns "2026-05-15T10:30:00.0000000" (no zone). We send the
        // `Prefer: outlook.timezone="UTC"` header for events, so interpret as
        // UTC. For mail, `receivedDateTime` is already a full ISO8601 string
        // (different field — handled directly).
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        if let d = f.date(from: raw) { return d }
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = f.date(from: raw) { return d }
        if let d = ISO8601DateFormatter.limor.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)
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
}

// MARK: - Microsoft Graph response shapes

private struct GraphCalendarResponse: Decodable {
    let value: [GraphCalendarEvent]
}

private struct GraphCalendarEvent: Decodable {
    let id: String
    let subject: String?
    let bodyPreview: String?
    let location: GraphLocation?
    let start: GraphDateTime?
    let end: GraphDateTime?
    let isAllDay: Bool?
}

private struct GraphLocation: Decodable {
    let displayName: String?
}

private struct GraphDateTime: Decodable {
    let dateTime: String?
    let timeZone: String?
}

private struct GraphMailListResponse: Decodable {
    let value: [GraphMailMessage]
}

private struct GraphMailMessage: Decodable {
    let id: String
    let subject: String?
    let from: GraphMailFrom?
    let receivedDateTime: String?
    let bodyPreview: String?
    let isRead: Bool?
    let categories: [String]?
    let internetMessageId: String?
}

private struct GraphMailFrom: Decodable {
    let emailAddress: GraphEmailAddress?
}

private struct GraphEmailAddress: Decodable {
    let name: String?
    let address: String?
}

private struct GraphMailBodyResponse: Decodable {
    let body: GraphMailBody?
}

private struct GraphMailBody: Decodable {
    let contentType: String?
    let content: String?
}

// MARK: - EmailDTO body builder
//
// Duplicated from GoogleAPIs.swift on purpose — both providers need the same
// shape, and keeping the helper file-private avoids accidental public surface.
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
            body_text: body
        )
    }
}
