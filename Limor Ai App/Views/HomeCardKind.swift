import SwiftUI

/// Identifies each card shown on the NowView home screen so the user can
/// reorder them. Cases are stable string-backed for safe persistence in
/// SharedStore — adding a new case won't break old saved orders.
enum HomeCardKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case nextReminder    = "reminder"
    case recommendations = "recommendations"
    case meetings        = "meetings"
    case emailActions    = "email_actions"
    case feed            = "feed"
    case nextFlight      = "flight"
    case weather         = "weather"
    case shopping        = "shopping"
    case health          = "health"
    case stats           = "stats"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextReminder:    return "התזכורת הבאה"
        case .recommendations: return "טיפ אישי"
        case .meetings:        return "הפגישות הבאות"
        case .emailActions:    return "מוקד המייל"
        case .feed:            return "חדשות אחרונות"
        case .nextFlight:      return "טיסה קרובה"
        case .weather:         return "מזג אוויר"
        case .shopping:        return "רשימת קניות"
        case .health:          return "בריאות"
        case .stats:           return "סטטיסטיקה"
        }
    }

    var icon: String {
        switch self {
        case .nextReminder:    return "bell.fill"
        case .recommendations: return "sparkles"
        case .meetings:        return "calendar.badge.clock"
        case .emailActions:    return "tray.full.fill"
        case .feed:            return "newspaper.fill"
        case .nextFlight:      return "airplane.departure"
        case .weather:         return "thermometer.medium"
        case .shopping:        return "cart.fill"
        case .health:          return "heart.fill"
        case .stats:           return "chart.bar.fill"
        }
    }

    var tint: Color {
        switch self {
        case .nextReminder:    return .limorIndigo
        case .recommendations: return .limorViolet
        case .meetings:        return .limorIndigo
        case .emailActions:    return .limorViolet
        case .feed:            return .limorPink
        case .nextFlight:      return Color(red: 0.20, green: 0.66, blue: 0.62)
        case .weather:         return .limorWarning
        case .shopping:        return .limorMint
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
        .meetings,
        .emailActions,
        .recommendations,
        .shopping,
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

    static func loadHidden() -> Set<HomeCardKind> {
        Set(SharedStore.homeCardHidden.compactMap { HomeCardKind(rawValue: $0) })
    }

    static func saveHidden(_ hidden: Set<HomeCardKind>) {
        SharedStore.homeCardHidden = hidden.map(\.rawValue)
    }
}
