import SwiftUI

/// Limor logo — three "person-with-heart" silhouettes side-by-side.
/// Backed by the `LimorLogoMark` image asset (purchased Fiverr design).
///
/// Use sizes:
///   • 28-44 pt → in-chat avatars / toolbar
///   • 76-130 pt → settings, splash logo
struct LimorLogoMark: View {
    var size: CGFloat = 120
    /// When non-nil, the logo is rendered onto a tinted square background
    /// (matches the App Store icon look). Pass nil for transparent.
    var background: Color? = nil
    /// Outer corner radius when `background` is set.
    var cornerRadius: CGFloat = 0

    var body: some View {
        ZStack {
            if let bg = background {
                if cornerRadius > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(bg)
                } else {
                    bg
                }
            }
            Image("LimorLogoMark")
                .resizable()
                .scaledToFit()
                .padding(size * 0.06)
        }
        .frame(width: size, height: size)
    }
}
