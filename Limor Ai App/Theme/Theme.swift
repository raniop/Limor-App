import SwiftUI

// MARK: - Brand Colors

extension Color {
    // Primary brand
    static let limorIndigo = Color(red: 0.314, green: 0.275, blue: 0.898)   // #504AE5
    static let limorViolet = Color(red: 0.545, green: 0.361, blue: 0.965)   // #8B5CF6
    static let limorPink   = Color(red: 0.918, green: 0.404, blue: 0.745)   // #EA67BE

    // Warm accents
    static let limorCoral  = Color(red: 1.0,   green: 0.420, blue: 0.420)   // #FF6B6B
    static let limorPeach  = Color(red: 1.0,   green: 0.620, blue: 0.450)   // #FF9F73
    static let limorMint   = Color(red: 0.341, green: 0.835, blue: 0.706)   // #57D5B4

    // Surfaces
    static let limorCanvas = Color(red: 0.984, green: 0.973, blue: 1.0)     // #FBF8FF
    static let limorInk    = Color(red: 0.102, green: 0.094, blue: 0.196)   // #1A1832
    static let limorMuted  = Color(red: 0.522, green: 0.510, blue: 0.604)   // #85829A
    /// Splash + LaunchScreen base. Soft pastel lavender — gentle, on-brand,
    /// lets the colorful logo and Hebrew text read clearly.
    static let splashBase  = Color(red: 0.937, green: 0.918, blue: 0.992)   // #EFEAFD

    // Status
    static let limorDanger  = Color(red: 0.949, green: 0.275, blue: 0.275)
    static let limorWarning = Color(red: 1.0,   green: 0.624, blue: 0.039)
    static let limorSuccess = Color(red: 0.196, green: 0.749, blue: 0.502)
}

// MARK: - ShapeStyle dot-shorthand
// Lets you write `.foregroundStyle(.limorInk)` instead of `.foregroundStyle(Color.limorInk)`.

extension ShapeStyle where Self == Color {
    static var limorIndigo:  Color { .limorIndigo }
    static var limorViolet:  Color { .limorViolet }
    static var limorPink:    Color { .limorPink }
    static var limorCoral:   Color { .limorCoral }
    static var limorPeach:   Color { .limorPeach }
    static var limorMint:    Color { .limorMint }
    static var limorCanvas:  Color { .limorCanvas }
    static var limorInk:     Color { .limorInk }
    static var limorMuted:   Color { .limorMuted }
    static var splashBase:   Color { .splashBase }
    static var limorDanger:  Color { .limorDanger }
    static var limorWarning: Color { .limorWarning }
    static var limorSuccess: Color { .limorSuccess }
}

// MARK: - Gradients

enum LimorGradient {
    static let brand = LinearGradient(
        colors: [.limorIndigo, .limorViolet],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let warm = LinearGradient(
        colors: [.limorCoral, .limorPeach],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let mint = LinearGradient(
        colors: [.limorMint, Color(red: 0.4, green: 0.85, blue: 0.78)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let sky = LinearGradient(
        colors: [Color(red: 0.45, green: 0.78, blue: 0.95), Color(red: 0.74, green: 0.88, blue: 1.0)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let dusk = LinearGradient(
        colors: [Color(red: 0.45, green: 0.36, blue: 0.78), Color(red: 0.95, green: 0.49, blue: 0.62)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Urgent / overdue accent — used by the Now hero when the next
    /// reminder has slipped past its due time, so the card itself
    /// signals "this needs attention" instead of relying on a small
    /// red pill on a calm purple background.
    static let danger = LinearGradient(
        colors: [.limorDanger, .limorCoral],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let canvas = LinearGradient(
        colors: [Color.limorCanvas, Color.white, Color.limorCanvas.opacity(0.6)],
        startPoint: .top, endPoint: .bottom
    )
}

// MARK: - Helpers

enum LimorTimeOfDay {
    case morning, noon, evening, night

    static var current: LimorTimeOfDay {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return .morning
        case 12..<17: return .noon
        case 17..<21: return .evening
        default: return .night
        }
    }

    var greeting: String {
        switch self {
        case .morning: return "בוקר טוב"
        case .noon:    return "צהריים טובים"
        case .evening: return "ערב טוב"
        case .night:   return "לילה טוב"
        }
    }

    var emoji: String {
        switch self {
        case .morning: return "🌅"
        case .noon:    return "☀️"
        case .evening: return "🌆"
        case .night:   return "🌙"
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .morning: return LimorGradient.warm
        case .noon:    return LimorGradient.sky
        case .evening: return LimorGradient.dusk
        case .night:   return LimorGradient.brand
        }
    }
}
