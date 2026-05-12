import SwiftUI
import UIKit

// MARK: - Dynamic color helper
//
// `Color(uiColor: UIColor { traits in … })` gives us a single Color that
// resolves to a different RGB on the fly depending on the current trait
// collection — auto-adapts to light / dark mode without us having to
// thread `@Environment(\.colorScheme)` into every view. SwiftUI honours
// this both inside `Color`, `LinearGradient` colors, etc.
private func dynamicColor(light: Color, dark: Color) -> Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
    })
}

// MARK: - Brand Colors

extension Color {
    // Primary brand — same hues in both themes (purple/pink/indigo read
    // well on both light and dark backgrounds; tweaking these would
    // dilute the brand).
    static let limorIndigo = Color(red: 0.314, green: 0.275, blue: 0.898)   // #504AE5
    static let limorViolet = Color(red: 0.545, green: 0.361, blue: 0.965)   // #8B5CF6
    static let limorPink   = Color(red: 0.918, green: 0.404, blue: 0.745)   // #EA67BE

    // Warm accents
    static let limorCoral  = Color(red: 1.0,   green: 0.420, blue: 0.420)   // #FF6B6B
    static let limorPeach  = Color(red: 1.0,   green: 0.620, blue: 0.450)   // #FF9F73
    static let limorMint   = Color(red: 0.341, green: 0.835, blue: 0.706)   // #57D5B4

    // Surfaces — these flip with the system appearance. Pick the dark
    // variants so that ink (text on background) stays readable, canvas
    // (page background) feels like a calm purple-tinted black, and
    // muted (secondary text) keeps the same perceptual contrast as in
    // light mode.
    static let limorCanvas = dynamicColor(
        light: Color(red: 0.984, green: 0.973, blue: 1.0),   // #FBF8FF
        dark:  Color(red: 0.043, green: 0.035, blue: 0.090)  // #0B0917
    )
    static let limorInk = dynamicColor(
        light: Color(red: 0.102, green: 0.094, blue: 0.196), // #1A1832
        dark:  Color(red: 0.953, green: 0.945, blue: 1.0)    // #F3F1FF
    )
    static let limorMuted = dynamicColor(
        light: Color(red: 0.522, green: 0.510, blue: 0.604), // #85829A
        dark:  Color(red: 0.620, green: 0.604, blue: 0.722)  // #9E9AB8
    )

    /// Splash + LaunchScreen base. Soft pastel lavender in light, a
    /// deep midnight indigo in dark — both keep the colourful logo +
    /// Hebrew tagline readable. Must match `UILaunchScreen` color so
    /// the cross-fade from launch into the SwiftUI splash is seamless.
    static let splashBase = dynamicColor(
        light: Color(red: 0.937, green: 0.918, blue: 0.992), // #EFEAFD
        dark:  Color(red: 0.082, green: 0.067, blue: 0.176)  // #15112D
    )

    // Status — slightly brighter in dark so they punch on a dark
    // background without losing the same character in light mode.
    static let limorDanger  = dynamicColor(
        light: Color(red: 0.949, green: 0.275, blue: 0.275),
        dark:  Color(red: 1.0,   green: 0.420, blue: 0.420)
    )
    static let limorWarning = dynamicColor(
        light: Color(red: 1.0,   green: 0.624, blue: 0.039),
        dark:  Color(red: 1.0,   green: 0.722, blue: 0.235)
    )
    static let limorSuccess = dynamicColor(
        light: Color(red: 0.196, green: 0.749, blue: 0.502),
        dark:  Color(red: 0.325, green: 0.851, blue: 0.620)
    )
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

    /// Page-background wash. The hard-coded `white` middle stop in the
    /// old gradient turned into a glaring band on dark mode (white →
    /// black → black), so we replace it with a second dynamic color
    /// (`limorCanvasMid`) that's near-white on light and a slightly
    /// lifted near-black on dark — still gives the gradient some
    /// movement, but stays on-theme.
    static let canvas = LinearGradient(
        colors: [Color.limorCanvas, Color.limorCanvasMid, Color.limorCanvas.opacity(0.6)],
        startPoint: .top, endPoint: .bottom
    )
}

private extension Color {
    /// Mid stop for the canvas gradient — only used by
    /// `LimorGradient.canvas`. Not exposed in the public Color palette
    /// because it's a gradient-internal detail.
    static let limorCanvasMid = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.063, green: 0.051, blue: 0.122, alpha: 1) // #100D1F
            : .white
    })
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
