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
    private static let bearerKey  = "limor.bearer"
    private static let baseURLKey = "limor.baseURL"
    private static let latKey     = "limor.lastLat"
    private static let lngKey     = "limor.lastLng"

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
                return UserGender.pick(
                    male:   "פתח קודם את אפליקציית לימור פעם אחת ואז נסה שוב — צריך התחברות עדכנית.",
                    female: "פתחי קודם את אפליקציית לימור פעם אחת ואז נסי שוב — צריך התחברות עדכנית."
                )
            case .expiredAuth:
                return UserGender.pick(
                    male:   "ההתחברות פגה. פתח את לימור לרגע ונסה שוב.",
                    female: "ההתחברות פגה. פתחי את לימור לרגע ונסי שוב."
                )
            case let .server(status, code):
                if status == 502 || code == "anthropic_failed" {
                    return UserGender.pick(
                        male:   "שירות ה-AI חזר עם שגיאה רגעית. נסה שוב בעוד דקה.",
                        female: "שירות ה-AI חזר עם שגיאה רגעית. נסי שוב בעוד דקה."
                    )
                }
                return "השרת החזיר שגיאה (\(status))."
            case .network:
                return "אין רשת או שהשרת לא מגיב."
            case .decode:
                return "תשובת השרת לא מובנת."
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
        guard let bearer = defaults.string(forKey: bearerKey), !bearer.isEmpty else {
            return .failure(.notAuthenticated)
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

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = timeout
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            return .failure(.decode(error))
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.server(status: -1, code: nil))
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(.expiredAuth)
            }
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
}
