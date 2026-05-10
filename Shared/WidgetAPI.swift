import Foundation

/// Tiny API client used by the widget extension. Falls back to cached `lastNow`
/// when the network is unreachable so the widget always has something to show.
enum WidgetAPI {
    static func fetchNow() async -> NowResponse? {
        guard let bearer = SharedStore.bearer, !bearer.isEmpty else {
            return SharedStore.loadLastNow()
        }

        var components = URLComponents(
            url: SharedStore.baseURL.appendingPathComponent("api/now"),
            resolvingAgainstBaseURL: false
        )!
        if let coord = SharedStore.lastCoordinate {
            components.queryItems = [
                URLQueryItem(name: "lat", value: String(coord.lat)),
                URLQueryItem(name: "lng", value: String(coord.lng)),
            ]
        }

        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 10
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return SharedStore.loadLastNow()
            }
            SharedStore.cacheLastNow(data)
            return try JSONDecoder().decode(NowResponse.self, from: data)
        } catch {
            return SharedStore.loadLastNow()
        }
    }
}
