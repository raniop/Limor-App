import Foundation

/// Minimal client for the Limor chat endpoint, designed to be called *from
/// inside the Share Extension*. The full `APIClient` brings FirebaseAuth and
/// a bunch of other deps along — the extension target can't afford those.
/// Auth here is a bearer token the main app stashed in the App Group
/// (`SharedStore.bearer`) on its most recent `freshIdToken` call.
///
/// Kept self-contained on purpose: this file reads from App Group
/// `UserDefaults` directly so the Share Extension target doesn't have to
/// drag in `SharedStore.swift` / `Models.swift` (which bring 700+ lines of
/// reminder/calendar/health types the extension has no use for). The key
/// names must stay in sync with `Shared/SharedStore.swift`.
///
/// Failure modes the caller has to be ready for:
///   - `.notAuthenticated`: bearer is missing or empty. Main app hasn't been
///     opened recently enough to refresh the App-Group token. UI should fall
///     back to enqueue-only and tell the user to open Limor at least once.
///   - `.expiredAuth`: backend returned 401. The cached token was minted
///     more than an hour ago. Same UI fallback as above.
///   - `.server`: anything else non-2xx. Includes the 502 anthropic_failed
///     hiccup we already see in the main app.
public enum ShareAPI {
    /// Must stay in sync with `SharedStore.appGroupId`. Redeclared here so
    /// this file compiles without dragging `SharedStore.swift` into the
    /// extension target.
    private static let appGroupId = "group.com.rani.Limor-Ai-App"
    private static let bearerKey       = "limor.bearer"
    private static let baseURLKey      = "limor.baseURL"
    private static let latKey          = "limor.lastLat"
    private static let lngKey          = "limor.lastLng"
    private static let refreshTokenKey = "limor.fbRefreshToken"
    private static let apiKeyKey       = "limor.fbApiKey"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupId) ?? .standard
    }

    public struct Reply: Sendable {
        public let text: String
    }

    public enum Failure: Error, LocalizedError {
        case notAuthenticated
        case expiredAuth
        case server(status: Int, code: String?)
        case network(Error)
        case decode(Error)
        case missingBaseURL

        public var errorDescription: String? {
            switch self {
            case .notAuthenticated, .missingBaseURL:
                return tr(UserGender.pick(
                    male:   "פתח קודם את אפליקציית לימור פעם אחת ואז נסה שוב — צריך התחברות עדכנית.",
                    female: "פתחי קודם את אפליקציית לימור פעם אחת ואז נסי שוב — צריך התחברות עדכנית."
                ), "Open the Limor app once, then try again — a current sign-in is needed.")
            case .expiredAuth:
                return tr(UserGender.pick(
                    male:   "ההתחברות פגה. פתח את לימור לרגע ונסה שוב.",
                    female: "ההתחברות פגה. פתחי את לימור לרגע ונסי שוב."
                ), "Your session expired. Open Limor for a moment and try again.")
            case let .server(status, code):
                if status == 502 || code == "anthropic_failed" {
                    return tr(UserGender.pick(
                        male:   "שירות ה-AI חזר עם שגיאה רגעית. נסה שוב בעוד דקה.",
                        female: "שירות ה-AI חזר עם שגיאה רגעית. נסי שוב בעוד דקה."
                    ), "The AI service had a brief hiccup. Try again in a minute.")
                }
                return tr("השרת החזיר שגיאה (\(status)).", "The server returned an error (\(status)).")
            case .network:
                return tr("אין רשת או שהשרת לא מגיב.", "No network, or the server isn't responding.")
            case .decode:
                return tr("תשובת השרת לא מובנת.", "The server's response couldn't be read.")
            }
        }
    }

    /// Sends a chat message (with optional image attachment) and returns
    /// Limor's reply text. Mirrors what the main app's `APIClient.sendChat`
    /// does — same endpoint, same JSON shape — but reads the bearer the
    /// main app mirrored to App Group instead of asking Firebase directly.
    public static func sendChat(
        message: String,
        attachmentData: Data?,
        attachmentMime: String?,
        attachmentFilename: String?,
        timeout: TimeInterval = 60
    ) async -> Result<Reply, Failure> {
        var bearer = defaults.string(forKey: bearerKey) ?? ""
        if bearer.isEmpty {
            // No cached id token — mint a fresh one from the refresh token.
            if let fresh = await mintFreshToken() { bearer = fresh }
            else { return .failure(.notAuthenticated) }
        }
        guard
            let baseRaw = defaults.string(forKey: baseURLKey),
            let baseURL = URL(string: baseRaw)
        else {
            return .failure(.missingBaseURL)
        }
        let url = baseURL.appendingPathComponent("api/chat")

        struct Body: Encodable {
            let message: String
            let user_lat: Double?
            let user_lng: Double?
            let attachment: Attachment?

            struct Attachment: Encodable {
                let content_type: String
                let data_base64: String
                let filename: String?
            }
        }
        struct ServerReply: Decodable {
            let reply: String
        }
        struct ServerError: Decodable {
            let error: String?
        }

        let attachment: Body.Attachment? = {
            guard let data = attachmentData, let mime = attachmentMime else { return nil }
            return Body.Attachment(
                content_type: mime,
                data_base64: data.base64EncodedString(),
                filename: attachmentFilename
            )
        }()

        // Coordinates are nice-to-have (for weather-aware replies) but the
        // extension can ship without them; the keys may simply not exist
        // yet on a fresh install.
        let lat = defaults.object(forKey: latKey) as? Double
        let lng = defaults.object(forKey: lngKey) as? Double
        let body = Body(message: message, user_lat: lat, user_lng: lng, attachment: attachment)

        let encodedBody: Data
        do { encodedBody = try JSONEncoder().encode(body) }
        catch { return .failure(.decode(error)) }

        // One attempt with the given bearer. 401 surfaces as `.expiredAuth` so
        // the caller can retry once after refreshing the token.
        func attempt(_ token: String) async -> Result<Reply, Failure> {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = timeout
            req.httpBody = encodedBody
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    return .failure(.server(status: -1, code: nil))
                }
                if http.statusCode == 401 { return .failure(.expiredAuth) }
                guard (200..<300).contains(http.statusCode) else {
                    let code = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
                    return .failure(.server(status: http.statusCode, code: code))
                }
                do {
                    let parsed = try JSONDecoder().decode(ServerReply.self, from: data)
                    return .success(Reply(text: parsed.reply))
                } catch {
                    return .failure(.decode(error))
                }
            } catch {
                return .failure(.network(error))
            }
        }

        let first = await attempt(bearer)
        // Token expired mid-flight → mint a fresh one and retry once.
        if case .failure(.expiredAuth) = first, let fresh = await mintFreshToken() {
            return await attempt(fresh)
        }
        return first
    }

    /// Exchange the stored Firebase refresh token for a fresh 1h id token via
    /// Google's Secure Token API, cache it as the new bearer, and return it.
    /// This is what lets the Share extension recover from an expired token
    /// without the user having to open the main app. Returns nil if there's no
    /// refresh token / API key, or the exchange fails.
    private static func mintFreshToken() async -> String? {
        guard
            let refresh = defaults.string(forKey: refreshTokenKey), !refresh.isEmpty,
            let apiKey = defaults.string(forKey: apiKeyKey), !apiKey.isEmpty,
            let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)")
        else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let form = "grant_type=refresh_token&refresh_token=\(refresh)"
        req.httpBody = form.data(using: .utf8)

        struct TokenResponse: Decodable {
            let id_token: String?
            let refresh_token: String?
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let parsed = try JSONDecoder().decode(TokenResponse.self, from: data)
            guard let idToken = parsed.id_token, !idToken.isEmpty else { return nil }
            defaults.set(idToken, forKey: bearerKey)
            // Google may rotate the refresh token — keep the newest.
            if let newRefresh = parsed.refresh_token, !newRefresh.isEmpty {
                defaults.set(newRefresh, forKey: refreshTokenKey)
            }
            return idToken
        } catch {
            return nil
        }
    }
}
