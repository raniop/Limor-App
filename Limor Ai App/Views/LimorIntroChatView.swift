import SwiftUI

/// "Meet Limor" intro chat shown once, after permissions onboarding and
/// before MainTabs. Asks 6 questions one at a time; Limor reacts briefly
/// after each. On the final answer we submit the whole set to the backend
/// as the seed of the user's profile facts (Limor extends it later via
/// the `remember_about_user` chat tool).
struct LimorIntroChatView: View {
    @EnvironmentObject private var auth: AuthManager
    var onCompleted: () -> Void

    /// One step of the intro — Limor asks `question`, the answer is stored
    /// under `factLabel` so the server can save it as a structured fact.
    private struct Step {
        let factLabel: String
        let question: String
        let placeholder: String
        let prefill: ((AuthManager) -> String?)?
    }

    private static let steps: [Step] = [
        Step(
            factLabel: "שם",
            question: "איך תרצה/י שאקרא לך?",
            placeholder: "לדוגמה: רני",
            prefill: { auth in auth.displayName }
        ),
        Step(
            factLabel: "גיל",
            question: "בן/בת כמה את/ה?",
            placeholder: "לדוגמה: 37",
            prefill: nil
        ),
        Step(
            factLabel: "משפחה",
            question: "מי בני המשפחה הקרובים שכדאי שאכיר? (בן/בת זוג, ילדים, הורים)",
            placeholder: "טקסט חופשי",
            prefill: nil
        ),
        Step(
            factLabel: "עיסוק",
            question: "במה את/ה עוסק/ת ביום-יום?",
            placeholder: "לדוגמה: סוכן ביטוח, מורה, בפנסיה",
            prefill: nil
        ),
        Step(
            factLabel: "עדיפות",
            question: "במה הכי חשוב לך שאעזור? תזכורות, יומן, בריאות, חדשות, או משהו אחר?",
            placeholder: "טקסט חופשי",
            prefill: nil
        ),
        Step(
            factLabel: "תחומי עניין",
            question: "תחביבים או דברים שמעניינים אותך, שכדאי שאדע?",
            placeholder: "לדוגמה: מנגנת פסנתר, אוהבת לטייל",
            prefill: nil
        ),
    ]

    @State private var stepIndex: Int = 0
    @State private var answers: [String] = []
    @State private var currentAnswer: String = ""
    @State private var typingLimor: Bool = false
    @State private var sending: Bool = false
    @State private var errorMessage: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            LiquidBackdrop()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            opener
                                .id("opener")
                            ForEach(0..<answers.count, id: \.self) { i in
                                limorBubble(text: Self.steps[i].question)
                                    .id("q-\(i)")
                                userBubble(text: answers[i])
                                    .id("a-\(i)")
                                // Hide the latest answer's ack while Limor is
                                // "typing" so the natural order is:
                                //   user answer → typing → ack → next question
                                let isLatest = i == answers.count - 1
                                if !isLatest || !typingLimor {
                                    limorBubble(text: ackForAnswer(at: i))
                                        .id("ack-\(i)")
                                }
                            }
                            // Render the in-flight question ONLY when the user
                            // hasn't already answered it. Without this guard
                            // we double up during the 700ms typing pause:
                            // ForEach already rendered Q[stepIndex] (since
                            // an answer for it exists), and we'd add a
                            // second copy here until stepIndex bumps.
                            if stepIndex < Self.steps.count, stepIndex >= answers.count {
                                limorBubble(text: Self.steps[stepIndex].question)
                                    .id("q-current")
                            }
                            if typingLimor {
                                typingIndicator.id("typing")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: stepIndex) { _, _ in scrollToBottom(proxy) }
                    .onChange(of: typingLimor) { _, _ in scrollToBottom(proxy) }
                    .onChange(of: answers.count) { _, _ in scrollToBottom(proxy) }
                }

                composer
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            currentAnswer = Self.steps[stepIndex].prefill?(auth) ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                inputFocused = true
            }
        }
        .alert("שגיאה", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("אוקיי", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var opener: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                LimorAvatar(size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("שלום, אני לימור")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.limorInk)
                    Text("לפני שנתחיל, כמה שאלות קצרות שיעזרו לי להכיר אותך. זה לוקח דקה.")
                        .font(.subheadline)
                        .foregroundStyle(.limorMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func limorBubble(text: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            LimorAvatar(size: 28)
            Text(text)
                .font(.body)
                .foregroundStyle(.limorInk)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [.white, .white.opacity(0.95)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.5), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 24)
        }
    }

    private func userBubble(text: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 24)
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(LimorGradient.brand)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.limorIndigo.opacity(0.25), radius: 10, y: 6)
                .frame(maxWidth: 280, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            LimorAvatar(size: 28)
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.limorIndigo.opacity(0.7))
                        .frame(width: 8, height: 8)
                        .scaleEffect(typingLimor ? 1.0 : 0.55)
                        .opacity(typingLimor ? 1.0 : 0.45)
                        .animation(
                            .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.18),
                            value: typingLimor
                        )
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
            )
            Spacer(minLength: 32)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(currentPlaceholder, text: $currentAnswer, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...4)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.5), lineWidth: 0.5)
                )
                .disabled(sending || typingLimor)

            Button {
                advance()
            } label: {
                ZStack {
                    if canSubmit {
                        Circle().fill(LimorGradient.brand)
                    } else {
                        Circle().fill(Color.limorMuted.opacity(0.3))
                    }
                    if sending {
                        ProgressView().tint(.white).scaleEffect(0.8)
                    } else {
                        Image(systemName: isFinalStep ? "checkmark" : "arrow.up")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)
                .shadow(color: canSubmit ? Color.limorIndigo.opacity(0.4) : .clear, radius: 10, y: 4)
            }
            .disabled(!canSubmit)
            .animation(.easeInOut, value: canSubmit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Helpers

    private var currentPlaceholder: String {
        guard stepIndex < Self.steps.count else { return "" }
        return Self.steps[stepIndex].placeholder
    }

    private var isFinalStep: Bool {
        stepIndex >= Self.steps.count - 1
    }

    private var canSubmit: Bool {
        !sending && !typingLimor &&
            !currentAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ackForAnswer(at i: Int) -> String {
        // Special-case the very first ack — the user just told us their name,
        // so warm-greet by it instead of a generic "נחמד מאוד".
        if i == 0, let name = answers.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "נעים מאוד, \(name)!"
        }
        // Tiny, varied acknowledgments for the rest — feels conversational
        // without pretending Limor is doing deep work.
        let acks = [
            "כיף לשמוע.",
            "הבנתי.",
            "מצוין.",
            "תודה ששיתפת.",
            "סבבה, רושמת.",
        ]
        return acks[(i - 1) % acks.count]
    }

    private func advance() {
        guard canSubmit else { return }
        let trimmed = currentAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        answers.append(trimmed)
        currentAnswer = ""

        if isFinalStep {
            Task { await submit() }
            return
        }

        // Show a fake typing indicator for ~700ms so Limor's next question
        // doesn't snap in instantly — gives the chat a human cadence.
        typingLimor = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            typingLimor = false
            stepIndex += 1
            currentAnswer = Self.steps[stepIndex].prefill?(auth) ?? ""
        }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        let drafts = zip(Self.steps, answers).map { step, value in
            ProfileFactDraft(label: step.factLabel, value: value)
        }
        do {
            _ = try await APIClient.shared.submitProfileIntro(facts: drafts)
            SharedStore.introCompleted = true
            onCompleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}
