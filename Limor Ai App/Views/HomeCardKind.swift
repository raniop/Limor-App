import SwiftUI

/// Identifies each card shown on the NowView home screen so the user can
/// reorder them. Cases are stable string-backed for safe persistence in
/// SharedStore — adding a new case won't break old saved orders.
enum HomeCardKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case nextReminder    = "reminder"
    case recommendations = "recommendations"
    case meetings        = "meetings"
    case tasks           = "tasks"
    case emailActions    = "email_actions"
    case feed            = "feed"
    case nextFlight      = "flight"
    case briefing        = "briefing"
    case expenses        = "expenses"
    case weather         = "weather"
    case shopping        = "shopping"
    case health          = "health"
    case stats           = "stats"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextReminder:    return tr("התזכורת הבאה", "Next reminder")
        case .recommendations: return tr("טיפ אישי", "Personal tip")
        case .meetings:        return tr("הפגישות הבאות", "Upcoming meetings")
        case .tasks:           return tr("המשימות שלי", "My tasks")
        case .emailActions:    return tr("מוקד המייל", "Email focus")
        case .feed:            return tr("חדשות אחרונות", "Latest news")
        case .nextFlight:      return tr("טיסה קרובה", "Upcoming flight")
        case .briefing:        return tr("תקציר מנהלים", "Executive briefing")
        case .expenses:        return tr("הוצאות החודש", "This month's expenses")
        case .weather:         return tr("מזג אוויר", "Weather")
        case .shopping:        return tr("רשימת קניות", "Shopping list")
        case .health:          return tr("בריאות", "Health")
        case .stats:           return tr("סטטיסטיקה", "Stats")
        }
    }

    var icon: String {
        switch self {
        case .nextReminder:    return "bell.fill"
        case .recommendations: return "sparkles"
        case .meetings:        return "calendar.badge.clock"
        case .tasks:           return "checklist"
        case .emailActions:    return "tray.full.fill"
        case .feed:            return "newspaper.fill"
        case .nextFlight:      return "airplane.departure"
        case .briefing:        return "briefcase.fill"
        case .expenses:        return "creditcard.fill"
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
        case .tasks:           return .limorIndigo
        case .emailActions:    return .limorViolet
        case .feed:            return .limorPink
        case .nextFlight:      return Color(red: 0.20, green: 0.66, blue: 0.62)
        case .briefing:        return Color(red: 0.27, green: 0.32, blue: 0.55)
        case .expenses:        return Color(red: 0.93, green: 0.60, blue: 0.20)
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
        .tasks,
        .emailActions,
        .recommendations,
        .shopping,
        .feed,
        .briefing,
        .nextFlight,
        .expenses,
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
