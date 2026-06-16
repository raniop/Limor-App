import SwiftUI

/// "Meet Limor" intro chat shown once, after permissions onboarding and
/// before MainTabs. Asks 6 questions one at a time; Limor reacts briefly
/// after each. On the final answer we submit the whole set to the backend
/// as the seed of the user's profile facts (Limor extends it later via
/// the `remember_about_user` chat tool).
struct LimorIntroChatView: View {
    @EnvironmentObject private var auth: AuthManager
    var onCompleted: () -> Void

    /// Hebrew is gendered — once we know the user's gender we can drop the
    /// awkward slash form ("את/ה") in every subsequent question.
    enum Gender: String, CaseIterable {
        case male, female, other

        var hebrewLabel: String {
            switch self {
            case .male:   return "זכר"
            case .female: return "נקבה"
            case .other:  return "אחר"
            }
        }
    }

    /// One step of the intro — Limor asks a question (in gendered form once
    /// gender is known), the answer is stored under `factLabel` so the
    /// server can save it as a structured fact.
    private struct Step {
        let factLabel: String
        /// Question text by gender. Falls back to `.male` if a form isn't
        /// provided. The "name" step uses a slash form on `.male` because
        /// gender is still unknown at that point.
        let texts: [Gender: String]
        let placeholder: String
        let prefill: ((AuthManager) -> String?)?
        let kind: Kind

        enum Kind { case text, genderSelect }

        func question(for gender: Gender) -> String {
            texts[gender] ?? texts[.male] ?? ""
        }
    }

    private static let steps: [Step] = [
        Step(
            factLabel: "שם",
            texts: [.male: tr("איך תרצה/י שאקרא לך?", "What would you like me to call you?")],
            placeholder: tr("לדוגמה: רני", "For example: Rani"),
            prefill: { auth in auth.displayName },
            kind: .text
        ),
        Step(
            factLabel: "מגדר",
            texts: [.male: tr("כדי שאדע לפנות אליך נכון — איזה גוף בעברית מתאים?", "So I address you correctly — which grammatical form in Hebrew fits?")],
            placeholder: "",
            prefill: nil,
            kind: .genderSelect
        ),
        Step(
            factLabel: "גיל",
            texts: [
                .male:   tr("בן כמה אתה?", "How old are you?"),
                .female: tr("בת כמה את?", "How old are you?"),
                .other:  tr("בן/בת כמה את/ה?", "How old are you?"),
            ],
            placeholder: tr("לדוגמה: 37", "For example: 37"),
            prefill: nil,
            kind: .text
        ),
        Step(
            factLabel: "עיסוק",
            texts: [
                .male:   tr("במה אתה עוסק ביום-יום?", "What do you do day to day?"),
                .female: tr("במה את עוסקת ביום-יום?", "What do you do day to day?"),
                .other:  tr("במה את/ה עוסק/ת ביום-יום?", "What do you do day to day?"),
            ],
            placeholder: tr("לדוגמה: סוכן ביטוח, מורה, בפנסיה", "For example: insurance agent, teacher, retired"),
            prefill: nil,
            kind: .text
        ),
        // Family relationships moved out of the intro — they're now picked
        // structurally in Settings → המשפחה שלי (linked to iOS Contacts).
        // This last step is the catch-all so the user can share anything
        // else that helps Limor personalise (hobbies, preferences, context).
        Step(
            factLabel: "היכרות כללית",
            texts: [
                .male:   tr("ספר לי קצת על עצמך — תחביבים, מה חשוב לך, או כל דבר שכדאי שאדע כדי לעזור טוב יותר.", "Tell me a bit about yourself — hobbies, what matters to you, or anything I should know to help you better."),
                .female: tr("ספרי לי קצת על עצמך — תחביבים, מה חשוב לך, או כל דבר שכדאי שאדע כדי לעזור טוב יותר.", "Tell me a bit about yourself — hobbies, what matters to you, or anything I should know to help you better."),
                .other:  tr("ספר/י לי קצת על עצמך — תחביבים, מה חשוב לך, או כל דבר שכדאי שאדע כדי לעזור טוב יותר.", "Tell me a bit about yourself — hobbies, what matters to you, or anything I should know to help you better."),
            ],
            placeholder: tr("טקסט חופשי", "Free text"),
            prefill: nil,
            kind: .text
        ),
    ]

    @State private var stepIndex: Int = 0
    @State private var answers: [String] = []
    @State private var currentAnswer: String = ""
    @State private var gender: Gender = .male  // overwritten on step 1 selection
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
                                limorBubble(text: Self.steps[i].question(for: gender))
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
                                limorBubble(text: Self.steps[stepIndex].question(for: gender))
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

                composerForStep
            }
        }
        // No `.preferredColorScheme(.light)` — the theme has dark
        // variants and the intro reads cleanly on either appearance.
        .onAppear {
            currentAnswer = Self.steps[stepIndex].prefill?(auth) ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                inputFocused = true
            }
        }
        .alert(tr("שגיאה", "Error"), isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(tr("אוקיי", "OK"), role: .cancel) {}
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
                    Text(tr("שלום, אני לימור", "Hi, I'm Limor"))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.limorInk)
                    Text(tr("לפני שנתחיל, כמה שאלות קצרות שיעזרו לי להכיר אותך. זה לוקח דקה.", "Before we begin, a few quick questions to help me get to know you. It takes a minute."))
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

    /// Pick the right composer for the current step. Gender selection
    /// presents three buttons; everything else uses the text composer.
    @ViewBuilder
    private var composerForStep: some View {
        if stepIndex < Self.steps.count, Self.steps[stepIndex].kind == .genderSelect {
            genderSelectBar
        } else {
            composer
        }
    }

    private var genderSelectBar: some View {
        HStack(spacing: 10) {
            ForEach(Gender.allCases, id: \.self) { g in
                Button {
                    selectGender(g)
                } label: {
                    Text(g.hebrewLabel)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(LimorGradient.brand)
                        )
                        .shadow(color: Color.limorIndigo.opacity(0.3), radius: 8, y: 4)
                }
                .disabled(typingLimor || sending)
                .opacity(typingLimor || sending ? 0.6 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
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
        // Step 0 (name) — warm-greet using the name they just gave.
        if i == 0, let name = answers.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return tr("נעים מאוד, \(name)!", "Nice to meet you, \(name)!")
        }
        // Step 1 (gender) — short, since it was a one-tap selection rather
        // than a sentence worth riffing on.
        if i == 1 { return tr("מעולה.", "Great.") }
        // Everything else — a small rotating set so the chat doesn't sound
        // robotic.
        let acks = [
            tr("כיף לשמוע.", "Nice to hear."),
            tr("הבנתי.", "Got it."),
            tr("מצוין.", "Excellent."),
            tr("תודה ששיתפת.", "Thanks for sharing."),
            tr("סבבה, רושמת.", "Cool, noting it down."),
        ]
        return acks[(i - 2) % acks.count]
    }

    private func advance() {
        guard canSubmit else { return }
        let trimmed = currentAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        answers.append(trimmed)
        currentAnswer = ""
        proceedAfterAnswer()
    }

    /// Tap handler for the three gender buttons. Records the choice as the
    /// answer for the current step and continues like a text answer.
    private func selectGender(_ g: Gender) {
        guard !typingLimor, !sending else { return }
        gender = g
        answers.append(g.hebrewLabel)
        // Mirror to the App Group right away so the Share Extension (and
        // anywhere else that reads `UserGender.current`) picks the correct
        // grammatical form for *this* user without waiting for the next
        // profile-facts refresh. Map the local enum 1:1.
        UserGender.store({
            switch g {
            case .male:   return .male
            case .female: return .female
            case .other:  return .other
            }
        }())
        proceedAfterAnswer()
    }

    /// Shared post-answer flow — show typing for 700ms, then bump stepIndex
    /// (or submit on the last step).
    private func proceedAfterAnswer() {
        if isFinalStep {
            Task { await submit() }
            return
        }
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

            // First answer is the preferred name. Sync it to the user's
            // display_name so Settings ("איך לימור פונה אליך") and the
            // home-screen greeting reflect the name they just gave —
            // otherwise they'd see the original Apple/Google account name
            // there and have to edit it manually. Failure here doesn't
            // block intro completion (the facts already saved).
            if let nameAnswer = answers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
               !nameAnswer.isEmpty {
                try? await auth.setDisplayName(nameAnswer)
            }

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
