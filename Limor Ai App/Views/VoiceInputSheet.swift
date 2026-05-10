import SwiftUI

/// Modal sheet that lets the user dictate to Limor in Hebrew or English.
/// Big animated mic, language toggle, live transcript. On confirm the text
/// is handed back to the chat composer (or sent immediately, see callers).
struct VoiceInputSheet: View {
    @StateObject private var voice = VoiceService.shared
    @Environment(\.dismiss) private var dismiss

    /// Called when the user confirms the dictation. The chat decides whether
    /// to send right away or just drop the text into the composer.
    var onConfirm: (String) -> Void

    @State private var locale: VoiceService.SpeechLocale = .hebrew
    @State private var animatePulse = false

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 24) {
                // Drag handle
                Capsule()
                    .fill(Color.limorMuted.opacity(0.4))
                    .frame(width: 38, height: 4)
                    .padding(.top, 10)

                header

                Spacer(minLength: 0)

                micVisual

                transcriptArea

                Spacer(minLength: 0)

                actionRow
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 22)
        }
        .task {
            // Auto-start so the user can begin talking immediately.
            await voice.start(locale: locale)
        }
        .onDisappear { voice.reset() }
        .alert("שגיאה", isPresented: .init(
            get: { voice.errorMessage != nil },
            set: { if !$0 { voice.errorMessage = nil } }
        )) {
            Button("אוקיי", role: .cancel) {}
        } message: {
            Text(voice.errorMessage ?? "")
        }
    }

    // MARK: - Header (language toggle + close)

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.limorMuted)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)

            Spacer()

            // Hebrew / English segmented picker
            HStack(spacing: 4) {
                ForEach(VoiceService.SpeechLocale.allCases) { l in
                    let selected = locale == l
                    Button {
                        guard locale != l else { return }
                        locale = l
                        Task { await voice.start(locale: l) }
                    } label: {
                        Text(l.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? .white : .limorInk)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(
                                Capsule().fill(selected ? Color.limorIndigo : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(.ultraThinMaterial))

            Spacer()
            // Mirror the X to keep the picker centered
            Color.clear.frame(width: 36, height: 36)
        }
    }

    // MARK: - Animated mic

    private var micVisual: some View {
        ZStack {
            // Outer reactive halo — scales with current mic level.
            Circle()
                .fill(Color.limorIndigo.opacity(0.15))
                .frame(width: 220, height: 220)
                .scaleEffect(0.85 + CGFloat(voice.audioLevel) * 0.45)
                .blur(radius: 16)
                .animation(.easeOut(duration: 0.12), value: voice.audioLevel)

            Circle()
                .fill(Color.limorViolet.opacity(0.20))
                .frame(width: 160, height: 160)
                .scaleEffect(animatePulse ? 1.06 : 0.94)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: animatePulse)

            Circle()
                .fill(LinearGradient(
                    colors: [Color.limorIndigo, Color.limorViolet],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 120, height: 120)
                .shadow(color: Color.limorIndigo.opacity(0.40), radius: 22, y: 10)

            Image(systemName: voice.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative.reversing, isActive: voice.isRecording)
        }
        .onAppear { animatePulse = true }
    }

    // MARK: - Live transcript

    private var transcriptArea: some View {
        VStack(spacing: 8) {
            Text(voice.isRecording ? "מקשיבה לך…" : "מוכן")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.limorMuted)

            ScrollView {
                Text(voice.transcript.isEmpty ? "תגיד משהו ללימור — היא מחכה." : voice.transcript)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(voice.transcript.isEmpty ? .limorMuted : .limorInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 140)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Bottom actions

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                voice.reset()
            } label: {
                Text("נקה")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .disabled(voice.transcript.isEmpty)
            .opacity(voice.transcript.isEmpty ? 0.5 : 1)

            // Toggle recording button
            Button {
                Task {
                    if voice.isRecording { voice.stop() }
                    else { await voice.start(locale: locale) }
                }
            } label: {
                Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 50)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [Color.limorIndigo, Color.limorViolet],
                            startPoint: .leading, endPoint: .trailing
                        ))
                    )
            }
            .buttonStyle(.plain)

            Button {
                let text = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                voice.stop()
                onConfirm(text)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Text("שלח")
                    Image(systemName: "paperplane.fill")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(Color.limorMint))
            }
            .buttonStyle(.plain)
            .disabled(voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
    }
}
