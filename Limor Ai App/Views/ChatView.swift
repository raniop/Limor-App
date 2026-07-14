import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var router: AppRouter
    @StateObject private var location = LocationManager.shared
    @StateObject private var voice = VoiceService.shared
    @State private var messages: [ChatMessage] = []
    @State private var usage: ChatUsage?
    @State private var isSending = false
    /// Tracks whether the on-screen keyboard is currently presented, driven
    /// by UIKit's `keyboardWillShow/Hide` notifications. Used to surface
    /// the "סגור מקלדת" nav-bar button only while it's actually useful —
    /// SwiftUI's `.toolbar(placement: .keyboard)` accessory bar was the
    /// obvious place for this but the Hebrew QuickType row sits on top
    /// of it and the button never became visible in practice.
    @State private var isKeyboardVisible = false
    @State private var errorMessage: String?
    /// First scroll-to-bottom on view appear is instant (no animation) so
    /// the chat opens already pinned to the latest message instead of
    /// playing a visible scroll animation from top to bottom every time
    /// the user enters the tab.
    @State private var initialScrollDone = false

    /// When the user's chat message looks like a recurring-reminder
    /// request ("תכניסי לי תזכורת קבועה כל יום ג׳ בשעה 8:15…") we open
    /// the editor pre-filled and let them review/save. nil = no draft
    /// pending. Cleared when the sheet dismisses.
    @State private var pendingRecurringDraft: RecurringReminderParser.Draft?

    // Voice-message gesture state.
    //
    // The mic supports two modes:
    //   • Press-and-hold (touch > 0.4s): record while pressed, release to
    //     send, drag left past `voiceCancelThreshold` to cancel.
    //   • Quick tap (touch < 0.4s, no real drag): "locks" the recording —
    //     the user can release their finger and the recording keeps going
    //     until they tap the mic again to send (or the cancel button in
    //     the banner to discard).
    @State private var voiceGestureActive = false
    @State private var voiceGestureOffset: CGFloat = 0
    @State private var voiceGestureStartedAt: Date?
    @State private var voiceLocked = false
    private let voiceCancelThreshold: CGFloat = 80
    private let voiceTapMaxDuration: TimeInterval = 0.4
    private let voiceTapMaxMovement: CGFloat = 20

    /// One-shot seed for the composer's internal `draft`. Parent writes to
    /// it (suggestion tap, queued pending message) and the composer picks
    /// it up via `.onChange` and clears back to nil. Kept here instead of
    /// inside the composer so suggestion buttons in `emptyState` (which
    /// live on the parent) can drive it.
    @State private var composerSeed: String?
    /// True while the composer has text — drives hiding the mic (WhatsApp-style).
    @State private var composerHasText = false

    // Attachment composer state
    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var showingVoiceMode = false
    @State private var attachmentData: Data?
    @State private var attachmentMime: String?
    @State private var attachmentFilename: String?
    @State private var attachmentImagePreview: UIImage?
    @State private var preparingAttachment = false


    private let suggestions: [ChatSuggestion] = [
        .init(icon: "bell.fill",          tint: .limorCoral,   text: tr("תזכירי לי בעוד שעה לבדוק דואר", "Remind me to check email in an hour")),
        .init(icon: "sun.max.fill",       tint: .limorWarning, text: tr("מה מזג האוויר עכשיו?", "What's the weather right now?")),
        .init(icon: "list.bullet",        tint: .limorMint,    text: tr("אילו תזכורות יש לי היום?", "What reminders do I have today?")),
        .init(icon: "calendar.badge.plus",tint: .limorViolet,  text: tr("תוסיפי תזכורת ליום ראשון 10:00", "Add a reminder for Sunday at 10:00")),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        ScrollView {
                            // VStack (not LazyVStack) so `.transition` on
                            // inserted bubbles actually fires. LazyVStack
                            // defers view creation until the row scrolls
                            // into range, which means new items get a
                            // first render *after* the withAnimation scope
                            // has already ended, and the transition is
                            // silently dropped. A chat is at most a few
                            // dozen bubbles, so the perf cost of eager
                            // rendering is negligible. `.equatable()` is
                            // still in place to keep CPU low when
                            // observable state (usage badge, etc.) flips.
                            VStack(alignment: .leading, spacing: 12) {
                                if messages.isEmpty {
                                    emptyState
                                }
                                ForEach(messages) { msg in
                                    MessageBubble(message: msg)
                                        .equatable()
                                        .id(msg.id)
                                        // Fires only when the append is
                                        // wrapped in `withAnimation` —
                                        // Limor's reply is, the user's
                                        // own bubble append is not, so
                                        // this entrance plays only for
                                        // the assistant.
                                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                                        .contextMenu {
                                            // Long-press → "Copy". Skip on
                                            // voice messages whose textual
                                            // content is just an
                                            // auto-transcript the user
                                            // didn't ask to see (the
                                            // optimistic user-side bubble
                                            // has content="").
                                            if !msg.content.isEmpty {
                                                Button {
                                                    UIPasteboard.general.string = msg.content
                                                } label: {
                                                    Label(tr("העתק", "Copy"), systemImage: "doc.on.doc")
                                                }
                                            }
                                        }
                                }
                                if isSending {
                                    TypingIndicator().transition(.opacity).id("typing")
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                            .limorReadableWidth()
                            // Tap anywhere on empty chat area dismisses the
                            // keyboard. SwiftUI prefers a child button's
                            // tap target over this container tap, so audio
                            // play buttons / suggestion rows still work
                            // normally — only blank space inside the
                            // scroll view dismisses.
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil
                                )
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: messages.count) { _, _ in
                            // First scroll (from empty → primed cache) is
                            // instant; subsequent message arrivals animate.
                            scrollToBottom(proxy, animated: initialScrollDone)
                            initialScrollDone = true
                        }
                        // Re-tapping the Chat tab while we're already on
                        // it jumps to the latest bubble — overrides iOS's
                        // default "scroll to top" behavior, which is the
                        // wrong direction for a thread anchored at the
                        // bottom.
                        .onChange(of: router.chatScrollToBottomNonce) { _, _ in
                            scrollToBottom(proxy, animated: true)
                        }

                        composer(scrollProxy: proxy)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        LimorAvatar(size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(tr("לימור", "Limor")).font(.subheadline.weight(.bold))
                            HStack(spacing: 4) {
                                Circle().fill(Color.limorSuccess).frame(width: 6, height: 6)
                                Text(tr("מקוונת", "Online")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                // ToolbarItemGroup keeps the toolbar shape constant so iOS
                // doesn't have to reconfigure the trailing slot every time
                // `usage` flips from nil → some — that reconfiguration is
                // a known crasher on iOS 18+ when combined with .principal.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let usage {
                        UsageBadge(usage: usage)
                    }
                }
                // Right-edge "back to feed" button (RTL → leading == right
                // visually). Dismisses the keyboard if up and returns the user
                // to the main feed tab.
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                        router.selectedTab = .now
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel(tr("חזרה לפיד", "Back to feed"))
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )) { _ in
                isKeyboardVisible = false
            }
            .task {
                location.requestWhenInUseAndStart()
                // Show cached history + overlay instantly so the tab feels
                // ready on the first frame — even before the server fetch
                // lands. `loadHistory()` runs after and silently replaces
                // these with the fresh server view.
                primeFromCache()
                await loadHistory()
                await consumePendingMessageIfAny()
            }
            // Refresh the chat when another device's iCloud write lands —
            // covers the case where the simulator did a shopping-list
            // interception (purely-local bubbles) and we want the iPhone's
            // chat tab to show those bubbles too.
            .onReceive(NotificationCenter.default.publisher(
                for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
            )) { _ in
                SharedStore.mirrorChatOverlayFromICloud()
                let overlay = SharedStore.chatLocalOverlay
                self.messages = mergeWithOverlay(server: SharedStore.chatHistoryCache, overlay: overlay)
            }
            .onChange(of: router.pendingChatMessage) { _, newValue in
                // The user tapped a CTA on another tab — fire it off as a
                // chat message as soon as it lands.
                guard newValue != nil else { return }
                Task { await consumePendingMessageIfAny() }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item: item) }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $photoItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleFileImport(result) }
            }
            .alert(tr("שגיאה", "Error"), isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(tr("אוקיי", "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: Binding(
                get: { pendingRecurringDraft != nil },
                set: { if !$0 { pendingRecurringDraft = nil } }
            )) {
                if let draft = pendingRecurringDraft {
                    RecurringReminderEditor(draft: draft) { reminder in
                        RecurringRemindersStore.shared.add(reminder)
                        Task { await RecurringRemindersScheduler.ensureAuthorization() }
                        // Append a confirmation bubble to the chat thread
                        // so the user sees what was actually saved.
                        let savedBubble = ChatMessage(
                            role: .assistant,
                            content: tr("✅ תזכורת קבועה נשמרה: \(reminder.task) — \(formatRecurringSummary(reminder))", "✅ Recurring reminder saved: \(reminder.task) — \(formatRecurringSummary(reminder))"),
                            created_at: ISO8601DateFormatter.limor.string(from: Date())
                        )
                        messages.append(savedBubble)
                        var overlay = SharedStore.chatLocalOverlay
                        overlay.append(savedBubble)
                        SharedStore.chatLocalOverlay = overlay
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .fullScreenCover(isPresented: $showingVoiceMode) {
                VoiceModeView()
                    .environmentObject(auth)
                    .environmentObject(router)
            }
        }
    }

    private func formatRecurringSummary(_ r: RecurringReminder) -> String {
        let time = String(format: "%02d:%02d", r.hour, r.minute)
        let weekdayShort = tr("א", "Su") + "," + tr("ב", "Mo") + "," + tr("ג", "Tu") + "," + tr("ד", "We") + "," + tr("ה", "Th") + "," + tr("ו", "Fr") + "," + tr("ש", "Sa")
        let weekdayList = weekdayShort.components(separatedBy: ",")
        let dayLabel: String
        if r.daysOfWeek.count == 7 {
            dayLabel = tr("כל יום", "Every day")
        } else if r.daysOfWeek == [1, 2, 3, 4, 5] {
            dayLabel = tr("ימי חול", "Weekdays")
        } else if r.daysOfWeek == [6, 7] {
            dayLabel = tr("סופ״ש", "Weekend")
        } else {
            dayLabel = r.daysOfWeek.sorted().map { weekdayList[$0 - 1] }.joined(separator: ", ")
        }
        return tr("\(dayLabel) ב-\(time)", "\(dayLabel) at \(time)")
    }

    // MARK: - Empty / suggestions

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 18) {
            Spacer(minLength: 24)
            ZStack {
                Circle().fill(Color.limorIndigo.opacity(0.07))
                    .frame(width: 120, height: 120)
                LimorAvatar(size: 76)
            }
            VStack(spacing: 4) {
                Text(tr("שלום! איך אפשר לעזור?", "Hi! How can I help?"))
                    .font(.title3.weight(.semibold))
                Text(tr("תשאלי אותי כל דבר, או שתיי לי מסמך / תמונה לניתוח (כרטיס טיסה, ביטוח, חשבונית).", "Ask me anything, or send me a document / photo to analyze (boarding pass, insurance, invoice)."))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 8) {
                ForEach(suggestions) { s in
                    SuggestionRow(suggestion: s) {
                        composerSeed = s.text
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private func composer(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            if voice.isRecordingVoiceMessage {
                voiceRecordingBanner
            } else if attachmentData != nil {
                attachmentBanner
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Input (with the send button) FIRST → in RTL it occupies the
                // right side, so send lands on the right. Accessory buttons
                // (mic / voice / attach) follow on the left.
                //
                // TextField + send button live in their own sub-view so
                // typing only invalidates THAT subview's body — not the
                // entire ChatView (which would re-evaluate the message list
                // on every keystroke). This was the root cause of the 99%
                // CPU spike while typing on the iPhone Air.
                ChatComposerInput(
                    isBusy: preparingAttachment || isSending || voice.isRecordingVoiceMessage,
                    hasAttachment: attachmentData != nil,
                    seed: $composerSeed,
                    scrollProxy: scrollProxy,
                    onSend: { text in
                        Task { await send(text: text) }
                    },
                    hasText: $composerHasText
                )

                // Mic hides while typing (WhatsApp-style) and returns when the
                // field is empty again.
                if !composerHasText {
                    micButton
                }

                // PhotosPicker placed *inside* a Menu silently fails to
                // present and prints _UIReparentingView warnings — known
                // SwiftUI issue. We trigger the picker via state from a
                // plain Button instead, and attach the actual
                // `.photosPicker` modifier at the view level below.
                Menu {
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label(tr("תמונה מהאלבום", "Photo from library"), systemImage: "photo")
                    }
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label(tr("מסמך / PDF", "Document / PDF"), systemImage: "doc.fill")
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.limorIndigo.opacity(0.12)))
                        .frame(width: 44, height: 44)
                }
                .disabled(preparingAttachment || isSending || voice.isRecordingVoiceMessage)
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

    /// Voice-mode entry — full-screen hands-free conversation. Distinct
    /// from `micButton` which records a one-shot voice message. This one
    /// opens a continuous loop where Limor also *talks back*. Extracted
    /// into its own computed property so the composer's HStack stays
    /// simple enough for the Swift compiler to type-check in a sensible
    /// timeframe — inlining all four composer buttons hits the
    /// "unable to type-check this expression" limit.
    private var voiceModeButton: some View {
        Button {
            showingVoiceMode = true
        } label: {
            Image(systemName: "waveform")
                .font(.body.weight(.semibold))
                .foregroundStyle(.limorPink)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.limorPink.opacity(0.12)))
                .frame(width: 44, height: 44)
        }
        .disabled(preparingAttachment || isSending || voice.isRecordingVoiceMessage)
        .accessibilityLabel(tr("שיחה קולית עם לימור", "Voice conversation with Limor"))
    }

    /// Mic button that drives the voice-message gesture. Two modes:
    ///   • Idle: shows the mic glyph; gesture below decides between a
    ///     quick tap (→ locked recording) and a long press (→ release-
    ///     to-send).
    ///   • Recording (locked or held): turns purple/red and the glyph
    ///     flips to "arrow.up" once we're in locked mode — at that point
    ///     a tap sends the clip.
    private var micButton: some View {
        let recording = voice.isRecordingVoiceMessage
        let locked = voiceLocked
        let cancelling = voiceGestureActive && voiceGestureOffset < -voiceCancelThreshold
        return Image(systemName: locked ? "arrow.up" : "mic.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(recording ? .white : Color.limorViolet)
            .frame(width: 38, height: 38)
            .background(
                Circle().fill(
                    recording
                        ? (cancelling ? Color.limorDanger : Color.limorViolet)
                        : Color.limorViolet.opacity(0.12)
                )
            )
            .scaleEffect(recording ? 1.25 : 1)
            .animation(.easeInOut(duration: 0.15), value: recording)
            .animation(.easeInOut(duration: 0.15), value: cancelling)
            .animation(.easeInOut(duration: 0.15), value: locked)
            // Outer 44pt frame so the mic shares a baseline with the send
            // button, paperclip, and TextField bubble in the composer
            // HStack. The visible 38pt circle stays centered inside; the
            // extra 3pt halo around it is also tappable, which makes the
            // press-and-hold easier to initiate.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(voiceGesture)
            .accessibilityLabel(locked ? tr("שלח הודעה קולית", "Send voice message") : tr("הקלטת הודעה קולית", "Record voice message"))
    }

    private var voiceGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !voiceGestureActive {
                    voiceGestureActive = true
                    voiceGestureStartedAt = Date()
                    // Don't start a recording while still sending the
                    // previous message — would step on its audio session.
                    guard !isSending, !preparingAttachment else { return }
                    // If already in locked-recording mode, this touch is
                    // the user about to tap "send"; do not kick off a new
                    // recording on top of the running one.
                    guard !voiceLocked else { return }
                    // Phone call in progress — the Phone app owns the
                    // mic, recording would either fail or produce silent
                    // audio. Surface a clear message and bail before
                    // touching the audio session.
                    if voice.isPhoneCallActive() {
                        errorMessage = tr("אי אפשר להקליט הודעה קולית בזמן שיחת טלפון. סיימי את השיחה ונסי שוב.", "Can't record a voice message during a phone call. End the call and try again.")
                        return
                    }
                    Task { await voice.startVoiceMessage() }
                }
                voiceGestureOffset = value.translation.width
            }
            .onEnded { value in
                let duration = voiceGestureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                let movement = max(abs(value.translation.width), abs(value.translation.height))
                let cancel = value.translation.width < -voiceCancelThreshold
                let quickTap = duration < voiceTapMaxDuration && movement < voiceTapMaxMovement

                voiceGestureActive = false
                voiceGestureOffset = 0
                voiceGestureStartedAt = nil

                if cancel {
                    _ = voice.stopVoiceMessage(cancel: true)
                    voiceLocked = false
                    return
                }

                if quickTap && !voiceLocked {
                    // First quick tap → enter locked recording. Keep the
                    // recorder running, user can now release their finger
                    // and tap the mic again to send.
                    voiceLocked = true
                    return
                }

                // Either a long-press release, or the locked-mode "send"
                // tap. Stop the recorder and ship it.
                let result = voice.stopVoiceMessage(cancel: false)
                voiceLocked = false
                if let result {
                    Task { await sendVoiceMessage(audioURL: result.url, duration: result.duration) }
                }
            }
    }

    /// Recording banner shown above the composer while the user holds the
    /// mic (or has locked the recording with a quick tap). Pulsing red dot +
    /// timer on the leading side; the trailing side flips between the
    /// "החלק לבטל" / "שחרר לביטול" press-and-hold hint and a tappable trash
    /// button + send hint for locked mode.
    private var voiceRecordingBanner: some View {
        let cancelling = voiceGestureActive && voiceGestureOffset < -voiceCancelThreshold
        return HStack(spacing: 10) {
            Circle()
                .fill(Color.limorDanger)
                .frame(width: 10, height: 10)
                .scaleEffect(0.9 + CGFloat(voice.voiceMessageLevel) * 0.5)
                .animation(.easeOut(duration: 0.1), value: voice.voiceMessageLevel)

            Text(formatRecordingDuration(voice.voiceMessageDuration))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.limorInk)

            Spacer(minLength: 8)

            if voiceLocked {
                Button {
                    _ = voice.stopVoiceMessage(cancel: true)
                    voiceLocked = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                            .font(.caption.weight(.bold))
                        Text(tr("ביטול", "Cancel"))
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.limorDanger)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.limorDanger.opacity(0.16)))
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: cancelling ? "trash.fill" : "chevron.left")
                        .font(.caption.weight(.bold))
                    Text(cancelling ? tr("שחרר לביטול", "Release to cancel") : tr("החלק לבטל", "Slide to cancel"))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(cancelling ? .limorDanger : .limorMuted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.limorDanger.opacity(cancelling ? 0.18 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.limorDanger.opacity(0.35), lineWidth: 0.6)
        )
    }

    private func formatRecordingDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var attachmentBanner: some View {
        HStack(spacing: 10) {
            attachmentThumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(attachmentFilename ?? tr("קובץ", "File"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let data = attachmentData {
                    Text(byteSizeString(data.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                clearAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.limorMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.limorIndigo.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.limorIndigo.opacity(0.25), lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private var attachmentThumbnail: some View {
        if let img = attachmentImagePreview {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.limorViolet.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "doc.fill")
                    .foregroundStyle(.limorViolet)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                // No withAnimation — jump straight to the bottom on the
                // first paint so the user doesn't see the chat scroll up
                // from the top every time the tab opens.
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Attachment loading

    private func loadPhoto(item: PhotosPickerItem) async {
        preparingAttachment = true
        defer {
            preparingAttachment = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                errorMessage = tr("לא הצלחתי לטעון את התמונה.", "Couldn't load the image.")
                return
            }
            let normalized = uiImage.normalizedOrientationChat()
            let resized = normalized.resizedChat(toMaxDimension: 1600)
            guard let jpeg = resized.jpegData(compressionQuality: 0.7) else {
                errorMessage = tr("לא הצלחתי לדחוס את התמונה.", "Couldn't compress the image.")
                return
            }
            if jpeg.count > 5_000_000 {
                errorMessage = tr("התמונה גדולה מ-5MB.", "The image is larger than 5MB.")
                return
            }
            attachmentData = jpeg
            attachmentMime = "image/jpeg"
            attachmentFilename = "image.jpg"
            attachmentImagePreview = resized
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        preparingAttachment = true
        defer { preparingAttachment = false }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                if data.count > 5_000_000 {
                    errorMessage = tr("הקובץ גדול מ-5MB. נסי קובץ קטן יותר.", "The file is larger than 5MB. Try a smaller file.")
                    return
                }
                let mime = mimeType(for: url)
                attachmentData = data
                attachmentMime = mime
                attachmentFilename = url.lastPathComponent
                if mime.hasPrefix("image/"), let img = UIImage(data: data) {
                    attachmentImagePreview = img
                } else {
                    attachmentImagePreview = nil
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }

    private func clearAttachment() {
        attachmentData = nil
        attachmentMime = nil
        attachmentFilename = nil
        attachmentImagePreview = nil
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType {
            return type
        }
        return "application/octet-stream"
    }

    private func byteSizeString(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    // MARK: - Networking

    /// Synchronously paint cached server history + the local overlay so
    /// the chat tab has content on the very first frame after the user
    /// taps it — even before the network round-trip in `loadHistory()`
    /// completes. Safe to call repeatedly: it only writes if our @State
    /// is still empty (so we don't clobber a freshly-loaded list).
    private func primeFromCache() {
        guard messages.isEmpty else { return }
        let cached = SharedStore.chatHistoryCache
        let overlay = SharedStore.chatLocalOverlay
        if !cached.isEmpty || !overlay.isEmpty {
            self.messages = mergeWithOverlay(server: cached, overlay: overlay)
        }
        if usage == nil {
            self.usage = SharedStore.chatUsageCache
        }
    }

    private func loadHistory() async {
        // Local overlay (shopping-list interception bubbles, etc.) is always
        // shown — even if the server fetch fails — so the user's quick
        // captures don't disappear on a tab switch or offline reload.
        let overlay = SharedStore.chatLocalOverlay
        do {
            let h = try await APIClient.shared.chatHistory(token: auth.token ?? "")
            self.messages = mergeWithOverlay(server: h.messages, overlay: overlay)
            self.usage = h.usage
            // Persist for the next cold launch — next time we'll have
            // something to paint synchronously and the user won't see
            // the empty-then-fill jump.
            SharedStore.chatHistoryCache = h.messages
            SharedStore.chatUsageCache = h.usage
        } catch {
            if messages.isEmpty {
                self.messages = SharedStore.chatHistoryCache.isEmpty ? overlay
                    : mergeWithOverlay(server: SharedStore.chatHistoryCache, overlay: overlay)
            }
            errorMessage = error.localizedDescription
        }
    }

    private func mergeWithOverlay(server: [ChatMessage], overlay: [ChatMessage]) -> [ChatMessage] {
        // Naive concat + sort by timestamp. Server messages never collide with
        // overlay messages (the overlay only holds bubbles the backend never
        // saw), so no dedup needed.
        (server + overlay).sorted { $0.created_at < $1.created_at }
    }

    /// If a CTA on another tab queued a message for Limor, fire it
    /// straight away. Clears the router slot whether the send succeeds
    /// or fails so we don't loop on a sticky pending value.
    private func consumePendingMessageIfAny() async {
        // A pending attachment (from the iOS Share Sheet handoff) can fire on
        // its own — caption may be empty when the user shares only an image.
        // We require *something* to send: either non-blank text or a queued
        // attachment.
        let queuedText = router.pendingChatMessage ?? ""
        let trimmed = queuedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachment = router.pendingChatAttachment != nil
        guard (!trimmed.isEmpty || hasAttachment), !isSending else { return }
        if let att = router.pendingChatAttachment {
            attachmentData = att.data
            attachmentMime = att.mime
            attachmentFilename = att.filename
            attachmentImagePreview = att.mime.hasPrefix("image/")
                ? UIImage(data: att.data)
                : nil
            router.pendingChatAttachment = nil
        }
        router.pendingChatMessage = nil
        await send(text: trimmed)
    }

    @MainActor
    private func send(text rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachmentData != nil else { return }
        // Flip `isSending` *before* any of the local-intercept branches
        // below (recurring-reminder parser, shopping detector). Those
        // branches return early — bypassing the eventual `isSending =
        // true` deeper in this function — and during their work the
        // button needs to be disabled too. Without this, repeatedly
        // shipping shopping items or recurring-reminder drafts in fast
        // succession would let a stale tap re-enter `send` before the
        // local intercept finished, occasionally creating the same
        // bubble pair twice.
        isSending = true
        defer { isSending = false }

        // Recurring-reminder intent — "תזכורת קבועה כל יום ג' בשעה 8:15…"
        // Open the editor pre-filled with whatever we parsed; the user
        // reviews/saves. We append the original message + a guidance
        // bubble so the chat thread reflects what happened.
        if attachmentData == nil, let draft = RecurringReminderParser.tryParse(text) {
            pendingRecurringDraft = draft
            let userBubble = ChatMessage(
                role: .user,
                content: text,
                created_at: ISO8601DateFormatter.limor.string(from: Date())
            )
            let replyBubble = ChatMessage(
                role: .assistant,
                content: tr("⏰ פתחתי לך טופס לתזכורת קבועה. תאשרי או תערכי ושמרי — אני אזכיר בלי backend.", "⏰ I opened a recurring-reminder form for you. Confirm or edit and save — I'll remind you without a backend."),
                created_at: ISO8601DateFormatter.limor.string(from: Date())
            )
            messages.append(userBubble)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                messages.append(replyBubble)
            }
            var overlay = SharedStore.chatLocalOverlay
            overlay.append(userBubble)
            overlay.append(replyBubble)
            SharedStore.chatLocalOverlay = overlay
            return
        }

        let payloadText = text.isEmpty ? defaultPromptForAttachment() : text
        let attachmentForServer: ChatAttachment? = {
            guard let data = attachmentData, let mime = attachmentMime else { return nil }
            return ChatAttachment(
                content_type: mime,
                data_base64: data.base64EncodedString(),
                filename: attachmentFilename
            )
        }()
        let optimisticImage = attachmentImagePreview?.jpegData(compressionQuality: 0.5)
        let optimisticFilename = attachmentFilename

        // Reset attachment state immediately so the user sees their action took effect.
        clearAttachment()

        let optimistic = ChatMessage(
            role: .user,
            content: payloadText,
            created_at: ISO8601DateFormatter.limor.string(from: Date()),
            localAttachmentImageData: optimisticImage,
            localAttachmentFilename: optimisticFilename
        )
        // User bubble appended plain (no withAnimation) on purpose — they
        // just tapped send, the action should feel immediate. Limor's
        // reply below gets the spring entrance.
        messages.append(optimistic)

        // isSending is already true from the top of this function — the
        // earlier check at line ~803 covered both this network-bound
        // path and the local-intercept early returns above.

        do {
            let reply = try await APIClient.shared.sendChat(
                token: auth.token ?? "",
                message: payloadText,
                lat: location.coordinate?.latitude,
                lng: location.coordinate?.longitude,
                attachment: attachmentForServer
            )
            usage = reply.usage
            applyShoppingActions(reply.shopping_actions)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: reply.reply,
                    created_at: ISO8601DateFormatter.limor.string(from: Date()),
                    flights: reply.flights,
                    hotels: reply.hotels
                ))
            }
        } catch {
            errorMessage = error.localizedDescription
            await loadHistory()
        }
    }

    /// Apply the shopping mutations Limor asked us to perform during
    /// this chat turn. The backend tracks every `add_shopping_item` /
    /// `complete_shopping_item` tool call and ships the names back in
    /// the chat reply — running them against the on-device store here
    /// is what makes the bottom-tab list update immediately, without
    /// depending on silent FCM pushes (which iOS deprioritises in
    /// foreground). `add` / `completeByName` already dedup, so a
    /// double-fire from a stray silent push won't add twice.
    @MainActor
    private func applyShoppingActions(_ actions: ChatReply.ShoppingActions?) {
        guard let actions else { return }
        for name in actions.adds {
            _ = ShoppingListStore.shared.add(name)
        }
        for name in actions.completes {
            _ = ShoppingListStore.shared.completeByName(name)
        }
    }

    private func defaultPromptForAttachment() -> String {
        guard let mime = attachmentMime else { return tr("תסתכלי על זה", "Take a look at this") }
        if mime.hasPrefix("image/") { return tr("מה רואים בתמונה? תסכמי לי את הפרטים החשובים.", "What's in the image? Summarize the key details for me.") }
        if mime == "application/pdf" { return tr("תסכמי לי את המסמך — מה הפרטים החשובים?", "Summarize the document for me — what are the key details?") }
        return tr("מה זה?", "What is this?")
    }

    /// Send a voice message: append an optimistic audio bubble immediately,
    /// transcribe the clip on-device, then POST the transcript + the audio
    /// file as a regular chat message + attachment. The transcript is what
    /// Limor actually "sees" — the audio attachment is uploaded for future
    /// server-side use but the current backend doesn't have to read it for
    /// the user-visible flow to work.
    @MainActor
    private func sendVoiceMessage(audioURL: URL, duration: TimeInterval) async {
        // Drop the local audio bubble into the chat right away so the user
        // sees their message immediately — same pattern as the text path.
        let optimistic = ChatMessage(
            role: .user,
            content: "",
            created_at: ISO8601DateFormatter.limor.string(from: Date()),
            localAudioURL: audioURL,
            localAudioDuration: duration
        )
        messages.append(optimistic)

        // Transcribe on-device first, *then* flip the typing indicator on
        // — otherwise the user would stare at "typing…" while we're still
        // running the local recognizer.
        let transcript = await voice.transcribeAudioFile(url: audioURL, locale: .hebrew)
        let trimmedTranscript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let messageText = trimmedTranscript.isEmpty ? tr("[הודעה קולית]", "[Voice message]") : trimmedTranscript

        // Load the M4A as base64. We don't fail the send if reading fails
        // — Limor can still respond to the transcript.
        let attachment: ChatAttachment? = {
            guard let data = try? Data(contentsOf: audioURL) else { return nil }
            return ChatAttachment(
                content_type: "audio/m4a",
                data_base64: data.base64EncodedString(),
                filename: "voice.m4a"
            )
        }()

        isSending = true
        defer { isSending = false }

        do {
            let reply = try await APIClient.shared.sendChat(
                token: auth.token ?? "",
                message: messageText,
                lat: location.coordinate?.latitude,
                lng: location.coordinate?.longitude,
                attachment: attachment
            )
            usage = reply.usage
            applyShoppingActions(reply.shopping_actions)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: reply.reply,
                    created_at: ISO8601DateFormatter.limor.string(from: Date()),
                    flights: reply.flights,
                    hotels: reply.hotels
                ))
            }
        } catch {
            errorMessage = error.localizedDescription
            await loadHistory()
        }
    }
}

// MARK: - Composer input (isolated so typing doesn't invalidate ChatView)

/// The TextField + Send button live here because typing fires a state
/// mutation on every keystroke, which re-runs the body of whoever owns
/// the @State. By keeping `draft` and `focused` local to this subview,
/// keystrokes only re-run *this* subview's body — the message list,
/// attachment banner, navigation toolbar, etc. all stay frozen.
private struct ChatComposerInput: View {
    /// True when send/attachment is in flight — disables the send button.
    let isBusy: Bool
    /// True when an attachment is staged — lets send fire even with empty draft.
    let hasAttachment: Bool
    /// One-shot inbound text from parent (suggestion tap / queued message).
    /// Composer replaces its draft with the seed, focuses, and clears.
    @Binding var seed: String?
    /// Lets the composer scroll the parent's message list to the bottom
    /// when the keyboard opens — otherwise the last message ends up
    /// hidden behind the keyboard.
    let scrollProxy: ScrollViewProxy
    /// Fires when the user taps Send. Receives the trimmed draft text.
    /// Composer clears its draft immediately for instant feedback.
    let onSend: (String) -> Void
    /// Mirrors "is there text" up to the parent so it can hide the mic while
    /// typing (WhatsApp-style). Only flips on empty↔non-empty transitions, so
    /// the parent doesn't re-render on every keystroke.
    @Binding var hasText: Bool

    @State private var draft: String = ""
    @FocusState private var focused: Bool
    /// Local lock that flips synchronously on tap to block double-fires
    /// from rapid taps before SwiftUI has propagated the parent's
    /// `isSending` flag back down through `isBusy`. The parent's
    /// `send(text:)` is `async` and the `isSending = true` line sits
    /// past several local-intercept branches (recurring-reminder
    /// parser, shopping-detector) — for the window between tap and
    /// `isSending = true`, the button would otherwise stay enabled
    /// and a quick second tap reached the server with the same text,
    /// which Limor noticed and replied "ראיתי שכתבת פעמיים".
    @State private var localSending: Bool = false

    private var canSend: Bool {
        guard !isBusy && !localSending else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachment
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // Send button FIRST so in the RTL layout it sits on the right edge
            // of the bar (the user found the left-side button confusing).
            Button {
                let toSend = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                // Hard-guard against rapid double-taps. Without this the
                // button's `.disabled(!canSend)` wasn't enough on its own —
                // a fast second tap could fire the closure before the
                // first tap's draft="" + parent's isSending=true had
                // re-rendered the disabled state, sending the same text
                // to the backend twice.
                guard !localSending else { return }
                guard !toSend.isEmpty || hasAttachment else { return }
                localSending = true
                draft = ""
                onSend(toSend)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    localSending = false
                }
            } label: {
                ZStack {
                    if canSend {
                        Circle().fill(LimorGradient.brand)
                    } else {
                        Circle().fill(Color.limorMuted.opacity(0.3))
                    }
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .shadow(color: canSend ? Color.limorIndigo.opacity(0.4) : .clear, radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)

            TextField(tr("הודעה ללימור…", "Message to Limor…"), text: $draft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .submitLabel(.return)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.limorBubbleBorder, lineWidth: 0.5)
                )
        }
        .onChange(of: draft) { _, newValue in
            // Report empty↔non-empty to the parent (drives mic visibility).
            // Setting the binding to the same value is a no-op in SwiftUI, so
            // this only re-renders the parent on an actual transition.
            let has = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if has != hasText { hasText = has }
        }
        .onChange(of: seed) { _, newValue in
            // Parent pushed text in (e.g. a suggestion). Apply it, focus,
            // and clear the seed so we don't keep reapplying.
            if let newValue, !newValue.isEmpty {
                draft = newValue
                focused = true
                seed = nil
            }
        }
        .onChange(of: focused) { _, isFocused in
            guard isFocused else { return }
            // Wait for the keyboard to slide in before scrolling — the
            // ScrollView's safe-area inset adjusts during the animation,
            // and a too-early scroll lands at the wrong offset.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeOut(duration: 0.25)) {
                    scrollProxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Suggestion

private struct ChatSuggestion: Identifiable, Hashable {
    let id = UUID()
    let icon: String
    let tint: Color
    let text: String
}

private struct SuggestionRow: View {
    let suggestion: ChatSuggestion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(suggestion.tint.opacity(0.15)).frame(width: 34, height: 34)
                    Image(systemName: suggestion.icon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(suggestion.tint)
                }
                Text(suggestion.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.limorInk)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bubble

private struct MessageBubble: View, Equatable {
    let message: ChatMessage

    /// SwiftUI uses this through `.equatable()` to skip re-rendering when
    /// nothing meaningful changed. `ChatMessage.id` is content-derived
    /// (role + timestamp + content hash), so equal IDs mean equal content
    /// — we don't need to hash the optimistic attachment Data on every
    /// keystroke just to confirm.
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.localAttachmentFilename == rhs.message.localAttachmentFilename
            && (lhs.message.localAttachmentImageData?.count
                == rhs.message.localAttachmentImageData?.count)
            && lhs.message.localAudioURL == rhs.message.localAudioURL
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                LimorAvatar(size: 28)
                // Travel cards get extra width — flight rows need room for
                // times + price on one line.
                bubble.frame(
                    maxWidth: (message.flights != nil || message.hotels != nil) ? 330 : 280,
                    alignment: .leading
                )
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 24)
                bubble.frame(maxWidth: 280, alignment: .trailing)
            }
        }
    }

    /// Inline-markdown rendering for bubbles: **bold**, *italic*, `code`
    /// and [tappable links](url), while keeping newlines as-is. Falls back
    /// to the raw string if parsing fails. Block markdown (tables, ###)
    /// isn't supported by SwiftUI Text — the backend prompt tells Limor
    /// not to emit those in chat.
    static func rendered(_ content: String) -> AttributedString {
        (try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(content)
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Voice message — render the player only and hide the transcript
            // text; the transcript is sent to Limor so she can reply in
            // context, but the user wanted WhatsApp-style bubbles that
            // *don't* surface the dictation.
            if let audioURL = message.localAudioURL {
                AudioPlayerControl(
                    url: audioURL,
                    duration: message.localAudioDuration ?? 0,
                    isUserBubble: message.role == .user
                )
            } else {
                if let data = message.localAttachmentImageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: 240, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if let filename = message.localAttachmentFilename {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                        Text(filename).lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.2)))
                }
                Text(Self.rendered(message.content))
                    .font(.body)
                    // Assistant links (booking pages etc.) — tappable, brand
                    // color. User bubbles are white-on-gradient, links there
                    // are rare; white keeps them legible.
                    .tint(message.role == .user ? .white : .limorIndigo)
                if let flights = message.flights, !flights.options.isEmpty {
                    FlightResultsCard(results: flights)
                }
                if let hotels = message.hotels, !hotels.properties.isEmpty {
                    HotelResultsCard(results: hotels)
                }
            }
        }
        .foregroundStyle(message.role == .user ? .white : .limorInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Group {
                if message.role == .user {
                    LimorGradient.brand
                } else {
                    // Dynamic surface — white in light, raised midnight
                    // purple in dark. The earlier hard-coded white
                    // gradient blew out the chat in dark mode and
                    // washed `.limorInk` (now near-white in dark) into
                    // invisibility.
                    Color.limorBubble
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(message.role == .user ? .clear : .limorBubbleBorder, lineWidth: 0.5)
        )
        .shadow(
            color: message.role == .user ? Color.limorIndigo.opacity(0.25) : .black.opacity(0.05),
            radius: message.role == .user ? 10 : 4,
            y: message.role == .user ? 6 : 2
        )
    }
}

// MARK: - Travel result cards (native rendering for search_flights / search_hotels)

/// Shared currency-symbol mapping for the travel cards.
private func currencySymbol(_ code: String?) -> String {
    switch (code ?? "USD").uppercased() {
    case "ILS": return "₪"
    case "USD": return "$"
    case "EUR": return "€"
    case "GBP": return "£"
    default:    return (code ?? "") + " "
    }
}

/// Flight options as a native card: big times, stops chip, bold price,
/// the best option highlighted, whole thing tappable into Google Flights.
private struct FlightResultsCard: View {
    let results: FlightSearchResults
    @Environment(\.openURL) private var openURL

    private var symbol: String { currencySymbol(results.currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Route header: "TLV ⇄ JFK · 20.7–24.7"
            HStack(spacing: 6) {
                Image(systemName: "airplane")
                    .font(.caption.weight(.bold))
                Text(routeTitle)
                    .font(.caption.weight(.bold))
                Spacer()
            }
            .foregroundStyle(.limorIndigo)

            ForEach(Array(results.options.prefix(3).enumerated()), id: \.element.id) { idx, opt in
                optionRow(opt, isBest: idx == 0)
            }

            if let urlStr = results.google_flights_url, let url = URL(string: urlStr) {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: 5) {
                        Text(tr("כל האופציות ב-Google Flights", "All options on Google Flights"))
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.limorIndigo)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.limorIndigo.opacity(0.10)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.limorIndigo.opacity(0.06))
        )
    }

    private var routeTitle: String {
        let route = [results.origin, results.destination].compactMap { $0 }
            .joined(separator: results.round_trip == true ? " ⇄ " : " ← ")
        let dates = [results.outbound_date, results.return_date]
            .compactMap { $0.flatMap(Self.shortDate) }
            .joined(separator: "–")
        return dates.isEmpty ? route : "\(route) · \(dates)"
    }

    /// "2026-07-20" → "20.7"
    private static func shortDate(_ iso: String) -> String? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return "\(d).\(m)"
    }

    @ViewBuilder
    private func optionRow(_ opt: FlightSearchResults.Option, isBest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(opt.airline)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.limorInk)
                    .lineLimit(1)
                if isBest {
                    Text(tr("מומלץ", "Best"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.limorSuccess))
                }
                Spacer()
                if let price = opt.price {
                    Text("\(symbol)\(Int(price).formatted())")
                        .font(.subheadline.weight(.heavy).monospacedDigit())
                        .foregroundStyle(.limorInk)
                }
            }

            HStack(spacing: 6) {
                timeBlock(opt.depart_time, airport: opt.depart_airport)
                Image(systemName: "arrow.forward")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.limorMuted)
                timeBlock(opt.arrive_time, airport: opt.arrive_airport, dayOffset: opt.arrivalDayOffset)
                Spacer()
                Text(stopsText(opt))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(opt.stops == 0 ? Color.limorSuccess : .limorMuted)
            }

            if let mins = opt.duration_minutes {
                Text(durationText(mins, stopovers: opt.stopover_airports))
                    .font(.caption2)
                    .foregroundStyle(.limorMuted)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.limorBubble)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isBest ? Color.limorSuccess.opacity(0.55) : .limorBubbleBorder, lineWidth: isBest ? 1.2 : 0.5)
        )
    }

    private func timeBlock(_ time: String, airport: String, dayOffset: Int = 0) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(time)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(.limorInk)
            if dayOffset > 0 {
                Text("+\(dayOffset)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.limorCoral)
            }
            if !airport.isEmpty {
                Text(airport)
                    .font(.caption2)
                    .foregroundStyle(.limorMuted)
            }
        }
    }

    private func stopsText(_ opt: FlightSearchResults.Option) -> String {
        switch opt.stops {
        case 0:  return tr("ישירה", "Nonstop")
        case 1:  return tr("עצירה אחת", "1 stop")
        default: return tr("\(opt.stops) עצירות", "\(opt.stops) stops")
        }
    }

    private func durationText(_ minutes: Int, stopovers: String?) -> String {
        let h = minutes / 60, m = minutes % 60
        let dur = m == 0 ? tr("\(h) שע׳", "\(h)h") : tr("\(h) שע׳ \(m) דק׳", "\(h)h \(m)m")
        if let s = stopovers, !s.isEmpty {
            return tr("משך: \(dur) · דרך \(s)", "Duration: \(dur) · via \(s)")
        }
        return tr("משך: \(dur)", "Duration: \(dur)")
    }
}

/// Hotel options card — name, rating, nightly price; row tap opens the
/// hotel's page.
private struct HotelResultsCard: View {
    let results: HotelSearchResults
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bed.double.fill")
                    .font(.caption.weight(.bold))
                Text(tr("מלונות", "Hotels"))
                    .font(.caption.weight(.bold))
                Spacer()
            }
            .foregroundStyle(.limorIndigo)

            ForEach(results.properties.prefix(4)) { hotel in
                Button {
                    if let link = hotel.link, let url = URL(string: link) { openURL(url) }
                } label: {
                    row(hotel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.limorIndigo.opacity(0.06))
        )
    }

    private func row(_ hotel: HotelSearchResults.Property) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hotel.name)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.limorInk)
                    .lineLimit(1)
                Spacer()
                if let rate = hotel.rate_per_night {
                    Text(tr("\(rate) / לילה", "\(rate) / night"))
                        .font(.footnote.weight(.heavy).monospacedDigit())
                        .foregroundStyle(.limorInk)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                if let rating = hotel.rating {
                    Text("⭐ \(rating, specifier: "%.1f")")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    if let reviews = hotel.reviews {
                        Text(tr("(\(reviews.formatted()) ביקורות)", "(\(reviews.formatted()) reviews)"))
                            .font(.caption2)
                            .foregroundStyle(.limorMuted)
                    }
                }
                if let cls = hotel.hotel_class, !cls.isEmpty {
                    Text(cls)
                        .font(.caption2)
                        .foregroundStyle(.limorMuted)
                        .lineLimit(1)
                }
                Spacer()
                if hotel.link != nil {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption2)
                        .foregroundStyle(.limorIndigo)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.limorBubble)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.limorBubbleBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    /// Three dots that pulse in sequence while Limor is typing. Uses
    /// TimelineView (lifecycle-bound) instead of `.repeatForever`, which
    /// would leak animation tickers across re-appearances of the view.
    /// An earlier attempt removed the pulse because we suspected it of
    /// causing the iPhone Air freeze, but the actual cause was a hung
    /// Firebase getIDToken — the dots were never the problem.
    var body: some View {
        HStack(spacing: 8) {
            LimorAvatar(size: 28)
            TimelineView(.periodic(from: .now, by: 0.18)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.18)
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        let on = ((tick + i) % 3) == 0
                        Circle()
                            .fill(Color.limorIndigo.opacity(0.7))
                            .frame(width: 8, height: 8)
                            .scaleEffect(on ? 1.0 : 0.55)
                            .opacity(on ? 1.0 : 0.45)
                            .animation(.easeInOut(duration: 0.4), value: on)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.limorBubble.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.limorBubbleBorder, lineWidth: 0.5)
            )
            Spacer(minLength: 32)
        }
    }
}

// MARK: - Audio message player (used inside MessageBubble for voice messages)

/// Tap-to-toggle play/pause for a voice-message bubble. Observes
/// VoiceService so the icon flips between play / pause when the user
/// taps it (or when playback finishes on its own).
private struct AudioPlayerControl: View {
    let url: URL
    let duration: TimeInterval
    let isUserBubble: Bool
    @ObservedObject private var voice = VoiceService.shared

    private var isPlaying: Bool { voice.playingAudioURL == url }
    private var tint: Color { isUserBubble ? .white : .limorIndigo }

    var body: some View {
        Button {
            voice.toggleAudioPlayback(url: url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.bold))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(tint.opacity(0.18)))

                // Decorative waveform — varying bar heights, no actual sample
                // data behind it, just a visual cue that this is audio.
                HStack(spacing: 2) {
                    ForEach(0..<22, id: \.self) { i in
                        Capsule()
                            .fill(tint.opacity(isPlaying ? 0.9 : 0.55))
                            .frame(width: 2, height: barHeight(for: i))
                    }
                }

                Text(formatDuration(duration))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint.opacity(0.85))
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 200, alignment: .leading)
    }

    private func barHeight(for index: Int) -> CGFloat {
        // Pseudo-random but stable per index — gives the bars some variation
        // without recomputing on each redraw.
        let pattern: [CGFloat] = [6, 12, 18, 10, 22, 14, 8, 20, 16, 12, 24, 10, 6, 18, 14, 22, 8, 16, 12, 20, 10, 14]
        return pattern[index % pattern.count]
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Usage badge

private struct UsageBadge: View {
    let usage: ChatUsage

    var body: some View {
        let lowRemaining = usage.remaining < 10
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.caption2.weight(.bold))
            Text("\(usage.remaining)").font(.caption.weight(.bold).monospacedDigit())
        }
        .foregroundStyle(lowRemaining ? Color.limorDanger : Color.limorIndigo)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill((lowRemaining ? Color.limorDanger : Color.limorIndigo).opacity(0.12)))
    }
}

// MARK: - UIImage helpers (chat-local to avoid colliding with SettingsView's)

private extension UIImage {
    func resizedChat(toMaxDimension max: CGFloat) -> UIImage {
        let largest = Swift.max(size.width, size.height)
        if largest <= max { return self }
        let scale = max / largest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    func normalizedOrientationChat() -> UIImage {
        if imageOrientation == .up { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
