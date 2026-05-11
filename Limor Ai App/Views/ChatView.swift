import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var router: AppRouter
    @StateObject private var location = LocationManager.shared
    @State private var messages: [ChatMessage] = []
    @State private var usage: ChatUsage?
    @State private var isSending = false
    @State private var errorMessage: String?

    /// One-shot seed for the composer's internal `draft`. Parent writes to
    /// it (suggestion tap, queued pending message) and the composer picks
    /// it up via `.onChange` and clears back to nil. Kept here instead of
    /// inside the composer so suggestion buttons in `emptyState` (which
    /// live on the parent) can drive it.
    @State private var composerSeed: String?

    // Attachment composer state
    @State private var photoItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var attachmentData: Data?
    @State private var attachmentMime: String?
    @State private var attachmentFilename: String?
    @State private var attachmentImagePreview: UIImage?
    @State private var preparingAttachment = false

    // Voice composer state
    @State private var showingVoiceSheet = false
    /// True when the most recent send was triggered from the voice sheet —
    /// the next reply should be spoken aloud automatically.
    @State private var expectVoiceReply = false

    private let suggestions: [ChatSuggestion] = [
        .init(icon: "bell.fill",          tint: .limorCoral,   text: "תזכירי לי בעוד שעה לבדוק דואר"),
        .init(icon: "sun.max.fill",       tint: .limorWarning, text: "מה מזג האוויר עכשיו?"),
        .init(icon: "list.bullet",        tint: .limorMint,    text: "אילו תזכורות יש לי היום?"),
        .init(icon: "calendar.badge.plus",tint: .limorViolet,  text: "תוסיפי תזכורת ליום ראשון 10:00"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidBackdrop()

                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if messages.isEmpty {
                                    emptyState
                                }
                                ForEach(messages) { msg in
                                    // .equatable() lets SwiftUI skip re-
                                    // rendering bubbles whose id hasn't
                                    // changed — every keystroke in the
                                    // composer triggers a body recalc, and
                                    // without this every bubble was being
                                    // diffed (including hashing any large
                                    // attachment Data), pegging the CPU.
                                    MessageBubble(message: msg)
                                        .equatable()
                                        .id(msg.id)
                                        // Transition only fires when the
                                        // append is inside a `withAnimation`
                                        // block — Limor's reply append is,
                                        // the user's own bubble append is
                                        // not, so this entrance plays only
                                        // for the assistant.
                                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                                }
                                if isSending {
                                    TypingIndicator().transition(.opacity).id("typing")
                                }
                                Color.clear.frame(height: 1).id("bottom")
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }

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
                            Text("לימור").font(.subheadline.weight(.bold))
                            HStack(spacing: 4) {
                                Circle().fill(Color.limorSuccess).frame(width: 6, height: 6)
                                Text("מקוונת").font(.caption2).foregroundStyle(.secondary)
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
            }
            .task {
                location.requestWhenInUseAndStart()
                await loadHistory()
                await consumePendingMessageIfAny()
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
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf, .image],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleFileImport(result) }
            }
            .sheet(isPresented: $showingVoiceSheet) {
                VoiceInputSheet { transcribed in
                    // Send the transcribed text straight away. Mark
                    // `expectVoiceReply` so Limor's reply gets spoken aloud
                    // — keeps the conversation hands-free.
                    expectVoiceReply = true
                    Task { await send(text: transcribed) }
                }
                .presentationDetents([.large])
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
                Text("שלום! איך אפשר לעזור?")
                    .font(.title3.weight(.semibold))
                Text("תשאלי אותי כל דבר, או שתיי לי מסמך / תמונה לניתוח (כרטיס טיסה, ביטוח, חשבונית).")
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
            if attachmentData != nil {
                attachmentBanner
            }

            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                        Label("תמונה מהאלבום", systemImage: "photo")
                    }
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("מסמך / PDF", systemImage: "doc.fill")
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.limorIndigo.opacity(0.12)))
                }
                .disabled(preparingAttachment || isSending)

                Button {
                    showingVoiceSheet = true
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorViolet)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.limorViolet.opacity(0.12)))
                }
                .disabled(isSending)

                // TextField + send button live in their own sub-view so
                // typing only invalidates THAT subview's body — not the
                // entire ChatView (which would re-evaluate the message list
                // on every keystroke). This was the root cause of the 99%
                // CPU spike while typing on the iPhone Air.
                ChatComposerInput(
                    isBusy: preparingAttachment || isSending,
                    hasAttachment: attachmentData != nil,
                    seed: $composerSeed,
                    scrollProxy: scrollProxy,
                    onSend: { text in
                        Task { await send(text: text) }
                    }
                )
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

    private var attachmentBanner: some View {
        HStack(spacing: 10) {
            attachmentThumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(attachmentFilename ?? "קובץ")
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) {
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
                errorMessage = "לא הצלחתי לטעון את התמונה."
                return
            }
            let normalized = uiImage.normalizedOrientationChat()
            let resized = normalized.resizedChat(toMaxDimension: 1600)
            guard let jpeg = resized.jpegData(compressionQuality: 0.7) else {
                errorMessage = "לא הצלחתי לדחוס את התמונה."
                return
            }
            if jpeg.count > 5_000_000 {
                errorMessage = "התמונה גדולה מ-5MB."
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
                    errorMessage = "הקובץ גדול מ-5MB. נסי קובץ קטן יותר."
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

    private func loadHistory() async {
        do {
            let h = try await APIClient.shared.chatHistory(token: auth.token ?? "")
            self.messages = h.messages
            self.usage = h.usage
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// If a CTA on another tab queued a message for Limor, fire it
    /// straight away. Clears the router slot whether the send succeeds
    /// or fails so we don't loop on a sticky pending value.
    private func consumePendingMessageIfAny() async {
        guard let queued = router.pendingChatMessage,
              !queued.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isSending
        else { return }
        router.pendingChatMessage = nil
        await send(text: queued)
    }

    @MainActor
    private func send(text rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachmentData != nil else { return }

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

        isSending = true
        defer { isSending = false }

        do {
            let reply = try await APIClient.shared.sendChat(
                token: auth.token ?? "",
                message: payloadText,
                lat: location.coordinate?.latitude,
                lng: location.coordinate?.longitude,
                attachment: attachmentForServer
            )
            usage = reply.usage
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: reply.reply,
                    created_at: ISO8601DateFormatter.limor.string(from: Date())
                ))
            }
            // If the user sent this message via the voice sheet, speak the
            // reply back so the conversation stays hands-free.
            if expectVoiceReply {
                expectVoiceReply = false
                VoiceService.shared.speak(reply.reply)
            }
        } catch {
            errorMessage = error.localizedDescription
            await loadHistory()
        }
    }

    private func defaultPromptForAttachment() -> String {
        guard let mime = attachmentMime else { return "תסתכלי על זה" }
        if mime.hasPrefix("image/") { return "מה רואים בתמונה? תסכמי לי את הפרטים החשובים." }
        if mime == "application/pdf" { return "תסכמי לי את המסמך — מה הפרטים החשובים?" }
        return "מה זה?"
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

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        guard !isBusy else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachment
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("הודעה ללימור…", text: $draft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .submitLabel(.send)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.5), lineWidth: 0.5)
                )

            Button {
                let toSend = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                // Clear immediately for instant visual feedback; parent
                // may decide to substitute defaultPromptForAttachment if
                // we passed empty text + an attachment.
                draft = ""
                onSend(toSend)
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
                .shadow(color: canSend ? Color.limorIndigo.opacity(0.4) : .clear, radius: 10, y: 4)
            }
            .disabled(!canSend)
            .animation(.easeInOut, value: canSend)
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
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                LimorAvatar(size: 28)
                bubble.frame(maxWidth: 280, alignment: .leading)
                Spacer(minLength: 24)
            } else {
                Spacer(minLength: 24)
                bubble.frame(maxWidth: 280, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Text(message.content)
                .font(.body)
        }
        .foregroundStyle(message.role == .user ? .white : .limorInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Group {
                if message.role == .user {
                    LimorGradient.brand
                } else {
                    LinearGradient(colors: [.white, .white.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(message.role == .user ? .clear : .white.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(
            color: message.role == .user ? Color.limorIndigo.opacity(0.25) : .black.opacity(0.05),
            radius: message.role == .user ? 10 : 4,
            y: message.role == .user ? 6 : 2
        )
    }
}

// MARK: - Typing indicator

private struct TypingIndicator: View {
    /// Static three-dot indicator. Earlier versions used TimelineView with a
    /// 180ms tick to pulse the dots, but on iPhone Air that update rate over
    /// `.regularMaterial` blur + LiquidBackdrop blur showed up as a GPU stall
    /// (3s Result accumulator timeout) the moment the indicator appeared on
    /// send. A static indicator is fine — the reply usually arrives within
    /// a second or two and the animation was barely perceived anyway.
    var body: some View {
        HStack(spacing: 8) {
            LimorAvatar(size: 28)
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in
                    Circle()
                        .fill(Color.limorIndigo.opacity(0.7))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                // Solid translucent fill instead of `.regularMaterial` —
                // material blur over the LiquidBackdrop blurs was the
                // expensive composition.
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.4), lineWidth: 0.5)
            )
            Spacer(minLength: 32)
        }
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
