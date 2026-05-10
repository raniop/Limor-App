import SwiftUI

/// Identifies each card shown on the NowView home screen so the user can
/// reorder them. Cases are stable string-backed for safe persistence in
/// SharedStore — adding a new case won't break old saved orders.
enum HomeCardKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case nextReminder    = "reminder"
    case recommendations = "recommendations"
    case feed            = "feed"
    case nextFlight      = "flight"
    case weather         = "weather"
    case health          = "health"
    case stats           = "stats"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextReminder:    return "התזכורת הבאה"
        case .recommendations: return "טיפ אישי"
        case .feed:            return "הפיד שלי"
        case .nextFlight:      return "טיסה קרובה"
        case .weather:         return "מזג אוויר"
        case .health:          return "בריאות"
        case .stats:           return "סטטיסטיקה"
        }
    }

    var icon: String {
        switch self {
        case .nextReminder:    return "bell.fill"
        case .recommendations: return "sparkles"
        case .feed:            return "newspaper.fill"
        case .nextFlight:      return "airplane.departure"
        case .weather:         return "thermometer.medium"
        case .health:          return "heart.fill"
        case .stats:           return "chart.bar.fill"
        }
    }

    var tint: Color {
        switch self {
        case .nextReminder:    return .limorIndigo
        case .recommendations: return .limorViolet
        case .feed:            return .limorPink
        case .nextFlight:      return Color(red: 0.20, green: 0.66, blue: 0.62)
        case .weather:         return .limorWarning
        case .health:          return .limorCoral
        case .stats:           return .limorMint
        }
    }
}

/// Persisted card order. Falls back to the canonical default when the user
/// hasn't customized yet, and back-fills any cards added in newer app
/// versions so they don't silently disappear from the home screen.
enum HomeCardOrder {
    static let defaultOrder: [HomeCardKind] = [
        .nextReminder,
        .recommendations,
        .feed,
        .nextFlight,
        .weather,
        .health,
        .stats,
    ]

    static func load() -> [HomeCardKind] {
        let saved = SharedStore.homeCardOrder
        guard !saved.isEmpty else { return defaultOrder }
        let parsed = saved.compactMap { HomeCardKind(rawValue: $0) }
        // Append any cards that the user's saved order doesn't include —
        // happens after an app update that introduces a new card.
        let missing = HomeCardKind.allCases.filter { !parsed.contains($0) }
        return parsed + missing
    }

    static func save(_ order: [HomeCardKind]) {
        SharedStore.homeCardOrder = order.map(\.rawValue)
    }
}
