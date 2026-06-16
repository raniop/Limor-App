import SwiftUI

/// Full-screen "phone call with Limor" voice mode. The user starts the
/// sheet, talks naturally, Limor replies aloud, and the conversation loops
/// until the user dismisses. Pipeline is:
///
///     listening (Apple SFSpeechRecognizer)
///       → silence detected after the user stops talking
///       → thinking (POST /api/chat with the transcript)
///       → speaking (AVSpeechSynthesizer reading the reply in Hebrew)
///       → back to listening (delegate callback)
///
/// Tapping the central orb in any state forces a transition: while
/// listening it ends the turn early; while speaking it interrupts Limor
/// and jumps to listening. Tapping the close button cancels the whole
/// loop and dismisses.
struct VoiceModeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var router: AppRouter
    @StateObject private var voice = VoiceService.shared
    @StateObject private var location = LocationManager.shared

    @State private var phase: Phase = .idle
    @State private var userTranscript: String = ""
    @State private var limorReply: String = ""
    @State private var errorMessage: String?

    enum Phase: Equatable {
        case idle              // permissions / first tap
        case listening         // recognizing speech
        case thinking          // /api/chat in flight
        case speaking          // Limor is talking
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 28) {
                Spacer()
                statusLabel
                orb
                caption
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .padding(.top, 24)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .task {
            await beginConversation()
        }
        .onDisappear {
            // Belt + suspenders: ensure mic + speaker are torn down even if
            // the sheet is swiped away while listening/speaking.
            voice.cancelVoiceModeListening()
            voice.stopSpeaking()
        }
        .alert(tr("שגיאה", "Error"), isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(tr("אוקיי", "OK"), role: .cancel) { dismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Subviews

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.05, blue: 0.18),
                Color(red: 0.18, green: 0.14, blue: 0.40),
                Color(red: 0.32, green: 0.18, blue: 0.55),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var statusLabel: some View {
        VStack(spacing: 4) {
            Text(tr("שיחה עם לימור", "Call with Limor"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
            Text(phaseLabel)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: phase)
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .idle:      return tr("מתכוננים…", "Getting ready…")
        case .listening: return voice.transcript.isEmpty ? tr("תדבר אליי", "Talk to me") : tr("מקשיב…", "Listening…")
        case .thinking:  return tr("חושבת…", "Thinking…")
        case .speaking:  return tr("לימור עונה", "Limor is answering")
        }
    }

    private var orb: some View {
        let baseSize: CGFloat = 220
        return ZStack {
            // Concentric expanding "sonar" rings — only while listening,
            // so the user has an unmistakable signal that the mic is hot.
            // Three rings phased 0/0.33/0.66 of a 1.4s cycle creates a
            // steady "going outward" feel; opacity fades as they expand.
            if phase == .listening {
                ForEach(0..<3, id: \.self) { i in
                    SonarRing(size: baseSize, delay: Double(i) * 0.45)
                }
            }

            // Soft outer halo
            Circle()
                .fill(Color.limorIndigo.opacity(0.25))
                .frame(width: baseSize + 80, height: baseSize + 80)
                .blur(radius: 30)
                .scaleEffect(orbScale)

            // Main orb
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.limorPink, Color.limorViolet, Color.limorIndigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: baseSize, height: baseSize)
                .scaleEffect(orbScale)
                .shadow(color: Color.limorIndigo.opacity(0.6), radius: 40, y: 12)

            // Inner highlight for the "depth" look
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.4), .clear],
                        center: .topLeading,
                        startRadius: 5,
                        endRadius: 120
                    )
                )
                .frame(width: baseSize, height: baseSize)
                .scaleEffect(orbScale)

            // Mic glyph while listening — concrete visual cue that beats
            // the abstract orb. Disappears when the orb is in any other
            // state.
            if phase == .listening {
                Image(systemName: "mic.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }

            // Thinking spinner
            if phase == .thinking {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .animation(.easeOut(duration: 0.10), value: orbScale)
        .onTapGesture { handleOrbTap() }
        .contentShape(Circle())
    }

    /// More dramatic range than before: 0.85…1.30 driven by mic level so
    /// even quiet speech moves the orb noticeably. Speaking and idle keep
    /// a soft fixed scale; thinking sits at 1.0 to let the spinner read.
    private var orbScale: CGFloat {
        switch phase {
        case .listening:
            return 0.85 + CGFloat(voice.audioLevel) * 0.45
        case .speaking:
            return 1.05
        case .thinking:
            return 1.0
        case .idle:
            return 0.97
        }
    }

    @ViewBuilder
    private var caption: some View {
        VStack(spacing: 8) {
            switch phase {
            case .listening:
                // Live transcript — bind directly to voice.transcript so
                // the user can *see* what Apple Speech is recognizing in
                // real time. Without this, mistranscriptions were the
                // mystery behind "she answered something else": the user
                // never saw what was actually heard.
                if voice.transcript.isEmpty {
                    Text(tr("תדבר אליי, אני שומעת אותך", "Talk to me, I'm listening"))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                } else {
                    Text(voice.transcript)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 8)
                }
            case .thinking:
                // Echo back what we actually sent so the user can spot
                // misrecognitions before/while Limor replies.
                if !userTranscript.isEmpty {
                    VStack(spacing: 4) {
                        Text(tr("שלחתי ללימור:", "Sent to Limor:"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(userTranscript)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 8)
                    }
                }
            case .speaking:
                if !limorReply.isEmpty {
                    Text(limorReply)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 8)
                        .transition(.opacity)
                }
            case .idle:
                EmptyView()
            }
        }
        .frame(minHeight: 90)
        .animation(.easeInOut(duration: 0.2), value: phase)
    }

    private var bottomBar: some View {
        HStack(spacing: 18) {
            Button {
                cancelAndDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .accessibilityLabel(tr("סגור", "Close"))

            Button {
                handleOrbTap()
            } label: {
                Image(systemName: orbActionIcon)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .accessibilityLabel(orbActionLabel)
        }
    }

    private var orbActionIcon: String {
        switch phase {
        case .listening: return "stop.fill"
        case .speaking:  return "speaker.slash.fill"
        case .thinking:  return "hourglass"
        case .idle:      return "mic.fill"
        }
    }

    private var orbActionLabel: String {
        switch phase {
        case .listening: return tr("סיים תור", "End turn")
        case .speaking:  return tr("השתק", "Mute")
        case .thinking:  return tr("ממתין", "Waiting")
        case .idle:      return tr("התחל", "Start")
        }
    }

    // MARK: - Flow control

    @MainActor
    private func beginConversation() async {
        // Avoid restarting if we re-enter the task (e.g. sheet stays open).
        guard phase == .idle else { return }
        let granted = await voice.requestPermissions()
        if !granted {
            errorMessage = voice.errorMessage ?? tr("צריך לאשר גישה למיקרופון וזיהוי דיבור.", "Microphone and speech recognition access is required.")
            return
        }
        await startListening()
    }

    @MainActor
    private func startListening() async {
        userTranscript = ""
        limorReply = ""
        phase = .listening
        // 1.0s silence threshold (was 1.5) — feels much more responsive
        // without breaking on natural pauses between words.
        await voice.startVoiceModeListening(locale: .hebrew, silenceSeconds: 1.0) {
            // onSilence — recognizer already stopped at this point.
            Task { @MainActor in
                await self.handleEndOfUserTurn()
            }
        }
    }

    @MainActor
    private func handleEndOfUserTurn() async {
        let text = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Apple Speech sometimes returns very short fragments like "אהה"
        // when the user just inhaled. Drop those and re-listen instead of
        // burning a chat round-trip on a no-op.
        guard text.count >= 2 else {
            await startListening()
            return
        }
        userTranscript = text
        phase = .thinking
        do {
            let coord = location.coordinate
            let reply = try await APIClient.shared.sendChat(
                token: auth.token ?? "",
                message: text,
                lat: coord?.latitude,
                lng: coord?.longitude,
                attachment: nil
            )
            limorReply = reply.reply
            phase = .speaking
            voice.speakAndComplete(reply.reply) {
                Task { @MainActor in
                    // After Limor finishes speaking, listen for the next turn.
                    await self.startListening()
                }
            }
        } catch is CancellationError {
            // View dismissed mid-flight — nothing to recover.
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            // Same — silent.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleOrbTap() {
        switch phase {
        case .idle:
            Task { await beginConversation() }
        case .listening:
            // Force end-of-turn early — useful when the user is in a noisy
            // environment and the silence-watchdog won't trip.
            voice.cancelVoiceModeListening()
            Task { await handleEndOfUserTurn() }
        case .speaking:
            // Interrupt Limor and go back to listening immediately.
            voice.stopSpeaking()
            Task { await startListening() }
        case .thinking:
            // No-op; can't cancel the in-flight chat call cleanly.
            break
        }
    }

    private func cancelAndDismiss() {
        voice.cancelVoiceModeListening()
        voice.stopSpeaking()
        dismiss()
    }
}

/// Concentric "sonar" ring that expands and fades. Stacked three deep in
/// the orb with staggered delays to give a continuous outward pulse —
/// the strongest visual signal that voice mode is actively listening,
/// independent of mic input level.
private struct SonarRing: View {
    let size: CGFloat
    let delay: Double

    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(Color.white.opacity(0.6), lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.6 : 1.0)
            .opacity(expanded ? 0 : 0.7)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.4)
                    .repeatForever(autoreverses: false)
                    .delay(delay)
                ) {
                    expanded = true
                }
            }
    }
}
