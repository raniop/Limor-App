import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var errorMessage: String?
    @State private var animateLogo = false
    @State private var googleInProgress = false

    var body: some View {
        ZStack {
            AnimatedMeshBackground()
                .blur(radius: 20)

            LinearGradient(
                colors: [.clear, Color.limorPink.opacity(0.08)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    LimorLogoMark(size: 124)
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                        .scaleEffect(animateLogo ? 1 : 0.85)
                        .opacity(animateLogo ? 1 : 0)
                        .animation(.spring(response: 0.7, dampingFraction: 0.7), value: animateLogo)

                    Text("לימור")
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .foregroundStyle(.limorInk)
                        .shadow(color: Color.limorIndigo.opacity(0.10), radius: 12, y: 4)
                        .opacity(animateLogo ? 1 : 0)
                        .offset(y: animateLogo ? 0 : 20)
                        .animation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1), value: animateLogo)

                    Text("העוזרת האישית החכמה שלך")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.limorMuted)
                        .opacity(animateLogo ? 1 : 0)
                        .animation(.easeOut(duration: 0.7).delay(0.25), value: animateLogo)
                }

                Spacer()

                VStack(spacing: 14) {
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            FeaturePill(icon: "bell.fill", text: "תזכורות")
                            FeaturePill(icon: "bubble.left.fill", text: "צ'אט")
                            FeaturePill(icon: "sun.max.fill", text: "מזג אוויר")
                        }
                        Text("ועוד הרבה דברים מגניבים ✨")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.limorMuted)
                    }

                    SignInWithAppleButton(.signIn) { request in
                        auth.prepareSignInRequest(request)
                    } onCompletion: { result in
                        Task { await handleAppleCompletion(result) }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

                    GoogleSignInButton(loading: googleInProgress) {
                        Task { await handleGoogle() }
                    }

                    Text("מתחברים דרך Firebase. הפרטים שלך מוצפנים 🔒")
                        .font(.caption)
                        .foregroundStyle(.limorMuted)
                        .multilineTextAlignment(.center)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(Color.limorDanger.opacity(0.85)))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 0.7)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .opacity(animateLogo ? 1 : 0)
                .offset(y: animateLogo ? 0 : 30)
                .animation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.35), value: animateLogo)
            }
        }
        .onAppear { animateLogo = true }
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            do {
                try await auth.completeSignIn(authorization: authorization)
            } catch {
                withAnimation { errorMessage = error.localizedDescription }
            }
        case .failure(let error):
            withAnimation { errorMessage = error.localizedDescription }
        }
    }

    private func handleGoogle() async {
        guard !googleInProgress else { return }
        googleInProgress = true
        defer { googleInProgress = false }
        do {
            try await auth.signInWithGoogle()
        } catch {
            // user-cancelled flows surface a localized "canceled" string we don't want to show
            let nsError = error as NSError
            if nsError.code != -5 { // GIDSignInError.canceled
                withAnimation { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.limorIndigo)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.limorIndigo.opacity(0.10)))
        .overlay(Capsule().stroke(Color.limorIndigo.opacity(0.18), lineWidth: 0.5))
    }
}

/// Custom Sign-in-with-Google button styled to match the Sign in with Apple button.
private struct GoogleSignInButton: View {
    let loading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if loading {
                    ProgressView().tint(.black.opacity(0.7))
                } else {
                    GoogleGlyph()
                        .frame(width: 22, height: 22)
                }
                Text("Sign in with Google")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.black.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        }
        .disabled(loading)
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// Hand-rolled Google "G" logo so we don't drag in an extra image asset.
private struct GoogleGlyph: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(size.width, size.height) / 2
            let lineWidth = radius * 0.30

            // Slice geometry — simplified Google G colors.
            let segments: [(start: Double, end: Double, color: Color)] = [
                (-90,    -90 + 90,  Color(red: 0.26, green: 0.52, blue: 0.96)),  // top right quadrant — blue
                (-90 + 90, -90 + 180, Color(red: 0.20, green: 0.66, blue: 0.33)),// bottom right — green
                (-90 + 180, -90 + 270, Color(red: 0.98, green: 0.74, blue: 0.02)),// bottom left — yellow
                (-90 + 270, -90 + 360, Color(red: 0.92, green: 0.26, blue: 0.21)),// top left — red
            ]
            for seg in segments {
                let path = Path { p in
                    p.addArc(center: center,
                             radius: radius - lineWidth/2,
                             startAngle: .degrees(seg.start),
                             endAngle: .degrees(seg.end),
                             clockwise: false)
                }
                context.stroke(path, with: .color(seg.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            // Inner horizontal bar of the G (small blue rect on right).
            let bar = CGRect(
                x: center.x,
                y: center.y - lineWidth * 0.45,
                width: radius - lineWidth * 0.4,
                height: lineWidth * 0.9
            )
            context.fill(Path(bar), with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))
            // Cover the small wedge between blue and red on top.
            let coverRect = CGRect(
                x: center.x - lineWidth * 0.05,
                y: 0,
                width: lineWidth * 0.4,
                height: lineWidth * 0.5
            )
            context.fill(Path(coverRect), with: .color(.white))
        }
    }
}
