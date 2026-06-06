import SwiftUI
import WidgetKit

/// Brand palette + reusable widget styling. Kept self-contained inside the
/// widget target so we don't have to pull `Theme.swift` (which depends on
/// main-app-only types). Colors mirror the main app's `Color.limor*`
/// values so the widgets feel like an extension of the app, not a
/// separate surface.
enum WidgetBrand {
    /// #504AE5 — primary brand color.
    static let indigo = Color(red: 0.314, green: 0.275, blue: 0.898)
    /// Purple between indigo and pink — the gradient anchor.
    static let violet = Color(red: 0.475, green: 0.298, blue: 0.875)
    /// Warm pink accent for callouts.
    static let pink = Color(red: 0.91, green: 0.42, blue: 0.71)
    /// Muted secondary text on light surfaces.
    static let muted = Color(red: 0.45, green: 0.42, blue: 0.55)
    /// Near-black brand ink (slightly purple-tinted).
    static let ink = Color(red: 0.10, green: 0.08, blue: 0.22)
    /// Off-white canvas, slightly pink.
    static let canvas = Color(red: 0.98, green: 0.96, blue: 1.00)
    /// Danger / overdue red.
    static let danger = Color(red: 0.94, green: 0.28, blue: 0.42)
    /// Success / done green.
    static let mint = Color(red: 0.32, green: 0.78, blue: 0.65)

    /// Main hero gradient (indigo → violet → pink). Used for the colored
    /// hero blocks inside widgets. Avoid as a full container background —
    /// system widgets respect the user's tint setting better when the
    /// container itself stays neutral.
    static let heroGradient = LinearGradient(
        colors: [indigo, violet, pink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle canvas gradient for the widget container background — very
    /// light, so dark-mode legibility doesn't break.
    static let canvasGradient = LinearGradient(
        colors: [
            Color(red: 0.97, green: 0.95, blue: 1.00),
            Color(red: 0.99, green: 0.97, blue: 1.00),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Helpers for the widget bodies. iOS 17+ uses `containerBackground` to
/// tint the widget chrome; older systems fall back to `.background`.
extension View {
    /// Brand canvas + RTL + tertiary fill fallback. Apply once at the
    /// outermost view of every widget body.
    @ViewBuilder
    func limorWidgetContainer() -> some View {
        self
            .environment(\.layoutDirection, .rightToLeft)
            .containerBackground(for: .widget) {
                ZStack {
                    WidgetBrand.canvasGradient
                    // Soft brand glow in the corner so the widget has
                    // a sense of color without overpowering the content.
                    Circle()
                        .fill(WidgetBrand.indigo.opacity(0.18))
                        .frame(width: 200, height: 200)
                        .blur(radius: 60)
                        .offset(x: -80, y: -80)
                }
            }
    }

    /// Place inside the widget body to add a colored "hero" block — used
    /// for the reminder hero in NowWidget. Internally clips to a rounded
    /// rect so decorative blurs don't leak past the block.
    func limorHeroBlock(cornerRadius: CGFloat = 14) -> some View {
        self
            .padding(12)
            .background(WidgetBrand.heroGradient)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Small, semantic label used at the top of each widget section.
struct WidgetSectionLabel: View {
    let icon: String
    let text: String
    var tint: Color = WidgetBrand.indigo

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WidgetBrand.muted)
        }
    }
}

/// Tiny rounded "pill" used for badges (e.g. "באיחור", count chips). Use
/// the `.danger`/`.mint`/`.indigo` flavors via the static helpers.
struct WidgetPill: View {
    let text: String
    let color: Color
    var filled: Bool = true

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.15))
            )
    }
}
