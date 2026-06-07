import SwiftUI

// MARK: - Liquid Glass background helper
//
// On iOS 26+ uses the new `glassEffect` (refractive, light-bending Liquid Glass).
// On older systems falls back to a frosted material with a subtle gradient stroke.

extension View {
    @ViewBuilder
    func liquidGlassBackground(cornerRadius: CGFloat = 24, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                liquidGlassStyle(tint: tint),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint?.opacity(0.10) ?? .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(LinearGradient(
                            colors: [Color.white.opacity(0.65), Color.white.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ), lineWidth: 0.7)
                )
                .shadow(color: Color.limorIndigo.opacity(0.10), radius: 22, y: 12)
        }
    }
}

@available(iOS 26.0, *)
private func liquidGlassStyle(tint: Color?) -> Glass {
    if let tint { return .regular.tint(tint.opacity(0.35)) }
    return .regular
}

// MARK: - Glass Card

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    var cornerRadius: CGFloat = 24
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassBackground(cornerRadius: cornerRadius, tint: tint)
    }
}

// MARK: - Liquid backdrop

/// Soft colorful glow blobs behind content, so Liquid Glass cards have something
/// vivid to refract. Use as a `.background` on a screen-level ZStack.
struct LiquidBackdrop: View {
    var body: some View {
        ZStack {
            LimorGradient.canvas.ignoresSafeArea()

            Circle()
                .fill(Color.limorIndigo.opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -140, y: -260)

            Circle()
                .fill(Color.limorPink.opacity(0.18))
                .frame(width: 360, height: 360)
                .blur(radius: 110)
                .offset(x: 180, y: 240)

            Circle()
                .fill(Color.limorMint.opacity(0.14))
                .frame(width: 280, height: 280)
                .blur(radius: 100)
                .offset(x: -100, y: 360)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Section header

struct SectionLabel: View {
    let icon: String
    let title: String
    var tint: Color = .limorMuted

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .textCase(.none)
    }
}

// MARK: - Brand button style

struct LimorPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LimorGradient.brand)
            )
            .shadow(color: Color.limorIndigo.opacity(0.35), radius: 14, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LimorPrimaryButtonStyle {
    static var limorPrimary: LimorPrimaryButtonStyle { LimorPrimaryButtonStyle() }
}

// MARK: - Stat pill

struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color = .limorIndigo

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption.weight(.bold))
                Text(value).font(.title3.weight(.bold).monospacedDigit())
            }
            .foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }
}

// MARK: - Animated mesh background

struct AnimatedMeshBackground: View {
    /// Soft pastel washes blended into the brand-colored corners. Each "color"
    /// here is the brand hue at very low opacity over a near-white base, so the
    /// mesh feels delicate instead of a saturated purple wall.
    private static let lavender = Color(red: 0.93, green: 0.91, blue: 0.99)
    private static let blush    = Color(red: 0.99, green: 0.91, blue: 0.95)
    private static let sky      = Color(red: 0.91, green: 0.95, blue: 1.00)
    private static let cream    = Color(red: 0.99, green: 0.97, blue: 1.00)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let p1 = Float(0.5 + sin(t * 0.30) * 0.10)
            let p2 = Float(0.5 + cos(t * 0.27) * 0.10)
            let p3 = Float(0.5 + sin(t * 0.21 + 1.0) * 0.10)
            let p4 = Float(0.5 + cos(t * 0.19 + 0.5) * 0.10)

            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0],            [p1, 0],            [1, 0],
                    [0, p2],           [p3, p4],           [1, 1 - p2],
                    [0, 1],            [1 - p1, 1],        [1, 1],
                ],
                colors: [
                    Self.lavender,     Self.blush,          Self.sky,
                    Self.blush,        Self.cream,          Self.lavender,
                    Self.sky,          Self.lavender,       Self.blush,
                ]
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - Limor avatar (used in chat + headers)

struct LimorAvatar: View {
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(LimorGradient.brand)
            LimorLogoMark(size: size * 0.78, background: nil)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.limorIndigo.opacity(0.4), radius: 8, y: 4)
    }
}

// MARK: - Page indicator dots

/// Small page-indicator used by carousels (RecommendationsCard, FeedCard,
/// etc.). Matches the visual the rest of the app uses instead of UIKit's
/// default page-style dots.
struct LimorPageDots: View {
    let count: Int
    let index: Int
    var activeColor: Color = .limorIndigo
    var inactiveColor: Color = .limorMuted

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == index ? activeColor : inactiveColor.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: index)
            }
        }
    }
}

/// Page-indicator + tap-to-navigate chevrons. Used on carousels that no
/// longer auto-advance — the chevrons flag manual navigation as a thing
/// the user can do, in addition to swiping. Wraps around at both ends so
/// the user never hits a "dead" arrow.
struct LimorPageControls: View {
    let count: Int
    let index: Int
    let onBack: () -> Void
    let onForward: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            chevronButton(symbol: "chevron.backward", action: onBack)
            LimorPageDots(count: count, index: index)
            chevronButton(symbol: "chevron.forward", action: onForward)
        }
    }

    private func chevronButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.limorIndigo)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.limorIndigo.opacity(0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty state

struct LimorEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var iconGradient: LinearGradient = LimorGradient.brand

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(iconGradient.opacity(0.15))
                    .frame(width: 88, height: 88)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(iconGradient)
            }
            VStack(spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - iPad / wide-screen adaptation

extension View {
    /// Cap + center content width on wide screens (iPad, landscape) so lists
    /// and cards read comfortably instead of stretching edge-to-edge. On
    /// iPhone (width already below the cap) it has no visible effect, so it's
    /// safe to apply to any scroll-content container.
    func limorReadableWidth(_ maxWidth: CGFloat = 680) -> some View {
        self
            .frame(maxWidth: maxWidth, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
