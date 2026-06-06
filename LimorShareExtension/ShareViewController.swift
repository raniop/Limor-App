import MobileCoreServices
import Social
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Hosts the iOS "Share to Limor" UI. Plain UIViewController + SwiftUI body
/// because SLComposeServiceViewController's chrome looks dated and can't be
/// restyled to match Limor.
///
/// Lifecycle:
///   1. `viewDidLoad` reads the share payload from `extensionContext` and
///      stashes it in instance state, then installs the SwiftUI compose UI.
///   2. The SwiftUI body owns a state machine (`Phase`) that walks compose
///      → sending → replied/failed. The view controller hands a `model` in
///      and observes its state changes via Combine.
///   3. On "Send", we kick off `ShareAPI.sendChat` directly — bypassing the
///      App-Group queue when the backend round-trip succeeds, so the user
///      sees Limor's reply *without* having to open the host app. The
///      backend persists both the user message and the reply to chat
///      history, so opening Limor later still shows the conversation.
///   4. On API failure (network/server/auth-expired), we fall back to the
///      App-Group queue so the next time the user opens the main app it
///      drains the message and tries again through `AppRouter`.
final class ShareViewController: UIViewController {
    private var sharedURLString: String?
    private var sharedText: String?
    private var sharedImageData: Data?
    private var hostingController: UIHostingController<ShareComposeRoot>?
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        loadAttachments { [weak self] in
            self?.installComposeUI()
        }
    }

    private func installComposeUI() {
        model.text = sharedText
        model.urlString = sharedURLString
        model.imageData = sharedImageData
        model.onSend = { [weak self] note in self?.handleSend(note: note) }
        model.onCancel = { [weak self] in self?.cancelShare() }
        model.onOpenApp = { [weak self] in self?.openHostApp() }
        model.onHandoffToApp = { [weak self] in self?.handoffToHostApp() }
        model.onRetry = { [weak self] in self?.retrySend() }
        model.onSendReply = { [weak self] text in self?.handleFollowUp(text: text) }
        model.onDone = { [weak self] in self?.completeShare() }

        let hc = UIHostingController(rootView: ShareComposeRoot(model: model))
        addChild(hc)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hc.didMove(toParent: self)
        hostingController = hc
    }

    private func cancelShare() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "com.rani.Limor-Ai-App.share", code: -1)
        )
    }

    private func completeShare() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// Last caption the user attempted to send. Stashed so the retry button
    /// in the failure UI can resend without making the user re-type.
    private var lastCaption: String?

    private func handleSend(note: String) {
        let caption = mergedCaption(note: note)
        lastCaption = caption
        attemptSend(caption: caption)
    }

    private func attemptSend(caption: String) {
        model.phase = .sending
        NSLog("[ShareExt] send begin caption=%@ hasImage=%@ imageBytes=%d",
              caption.prefix(40).description,
              sharedImageData == nil ? "false" : "true",
              sharedImageData?.count ?? 0)

        Task { [weak self, sharedImageData] in
            let result = await ShareAPI.sendChat(
                message: caption,
                attachmentData: sharedImageData,
                attachmentMime: sharedImageData == nil ? nil : "image/jpeg",
                attachmentFilename: sharedImageData == nil
                    ? nil
                    : "shared-\(UUID().uuidString.prefix(8)).jpg"
            )
            await MainActor.run {
                guard let self else { return }
                switch result {
                case let .success(reply):
                    NSLog("[ShareExt] API success — reply length=%d", reply.text.count)
                    self.model.conversation = [
                        ShareModel.Turn(role: .limor, text: reply.text)
                    ]
                    self.model.phase = .active
                case let .failure(err):
                    NSLog("[ShareExt] API failed: %@", err.localizedDescription)
                    self.model.phase = .failed(message: err.localizedDescription)
                }
            }
        }
    }

    /// Send a follow-up message inside the same Share-Extension session.
    /// The first send (initial share) goes through `attemptSend`; once the
    /// conversation is `.active`, every subsequent user turn flows through
    /// here. No attachment on follow-ups — the original image/URL was sent
    /// on the first call; the backend keeps the chat history server-side,
    /// so the next /api/chat call sees the full prior context.
    private func handleFollowUp(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !model.isReplying else { return }
        // Optimistically append the user's bubble + clear the composer so
        // the UI feels instant.
        model.conversation.append(ShareModel.Turn(role: .user, text: trimmed))
        model.reply = ""
        model.isReplying = true
        NSLog("[ShareExt] follow-up send: %@", trimmed.prefix(40).description)

        Task { [weak self] in
            let result = await ShareAPI.sendChat(
                message: trimmed,
                attachmentData: nil,
                attachmentMime: nil,
                attachmentFilename: nil
            )
            await MainActor.run {
                guard let self else { return }
                self.model.isReplying = false
                switch result {
                case let .success(reply):
                    NSLog("[ShareExt] follow-up success — reply length=%d", reply.text.count)
                    self.model.conversation.append(
                        ShareModel.Turn(role: .limor, text: reply.text)
                    )
                case let .failure(err):
                    NSLog("[ShareExt] follow-up failed: %@", err.localizedDescription)
                    // Append a system-style note as a Limor bubble so the
                    // user sees their message wasn't lost (it's already
                    // optimistically in the thread) and what went wrong.
                    let msg = err.localizedDescription
                    self.model.conversation.append(
                        ShareModel.Turn(role: .limor, text: "⚠️ \(msg)")
                    )
                }
            }
        }
    }

    private func retrySend() {
        guard let caption = lastCaption else { return }
        attemptSend(caption: caption)
    }

    /// When the user taps "open in app" from the failure UI: enqueue so the
    /// main app's foreground drain can pick it up and retry through the
    /// normal chat send. Only called from explicit "open" — not on auto-
    /// fail — so we never leave an orphan in the inbox after a retry that
    /// eventually succeeded inline.
    private func handoffToHostApp() {
        guard let caption = lastCaption else {
            openHostApp()
            return
        }
        _ = ShareInbox.enqueue(text: caption, imageData: sharedImageData)
        NSLog("[ShareExt] handoff — enqueued for host-app retry")
        openHostApp()
    }

    /// Combine the user-typed note with whatever came in from the share
    /// sheet. Avoids duplicating text the user already sees in the preview.
    private func mergedCaption(note: String) -> String {
        var parts: [String] = []
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { parts.append(trimmedNote) }
        if let text = sharedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, text != trimmedNote {
            parts.append(text)
        }
        if let url = sharedURLString, !url.isEmpty {
            parts.append(url)
        }
        // Mirror the main app's "default prompt when only an attachment"
        // behavior so Limor doesn't get a blank message string with just a
        // base64 blob — that confuses the system prompt.
        if parts.isEmpty && sharedImageData != nil {
            parts.append("מה רואים בתמונה? תסכמי לי את הפרטים החשובים.")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Opening the host app
    //
    // Two paths, in order:
    //
    //   1. `extensionContext.open(_:completionHandler:)` — works on iOS 17+
    //      for share extensions in practice (the Apple docs say "may not"
    //      but every shipping app uses it). This is what actually launches
    //      the host app on modern iOS.
    //
    //   2. Responder-chain walk to UIApplication's legacy `openURL:` —
    //      kept as a safety net for older iOS or edge cases where (1)
    //      silently returns false.
    //
    // Either way we dismiss the extension after a short delay so iOS has
    // time to transition before our UI tears down — otherwise on slower
    // devices the dismiss visibly races with the app launch and the user
    // sees a "closes back to the source app" flash.

    private func openHostApp() {
        // App-Group fallback flag — set unconditionally so the host app's
        // foreground hook can switch to the chat tab even when neither
        // `extensionContext.open` nor the responder-chain trick manages to
        // actually launch the app. Cleared on the host side after consumed.
        ShareInbox.shouldOpenChat = true
        NSLog("[ShareExt] set shouldOpenChat=true (App Group fallback)")

        guard let url = URL(string: "limor://share") else {
            completeShare()
            return
        }
        guard let ctx = extensionContext else {
            _ = openViaResponderChain(url: url)
            scheduleCompleteShare()
            return
        }
        ctx.open(url) { [weak self] success in
            NSLog("[ShareExt] extensionContext.open success=%@", success ? "true" : "false")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !success {
                    _ = self.openViaResponderChain(url: url)
                }
                self.scheduleCompleteShare()
            }
        }
    }

    private func scheduleCompleteShare() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.completeShare()
        }
    }

    @discardableResult
    private func openViaResponderChain(url: URL) -> Bool {
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self.next
        while let r = responder {
            if r.responds(to: selector) {
                _ = r.perform(selector, with: url)
                NSLog("[ShareExt] openURL via responder chain: %@", String(describing: type(of: r)))
                return true
            }
            responder = r.next
        }
        NSLog("[ShareExt] responder chain exhausted; nobody responds to openURL:")
        return false
    }

    // MARK: Attachment loading

    private func loadAttachments(completion: @escaping () -> Void) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem else {
            completion()
            return
        }
        let providers = item.attachments ?? []
        let group = DispatchGroup()
        for provider in providers {
            // Images get priority — a single provider that exposes both an
            // image type *and* a URL (e.g. Photos shares an asset URL
            // alongside the JPEG bytes) is richer as image.
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                    defer { group.leave() }
                    guard let self, let data else { return }
                    self.sharedImageData = self.normalizeToJPEG(data)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                    defer { group.leave() }
                    if let url = item as? URL { self?.sharedURLString = url.absoluteString }
                    else if let s = item as? String { self?.sharedURLString = s }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                    defer { group.leave() }
                    if let s = item as? String { self?.sharedText = s }
                }
            }
        }
        group.notify(queue: .main) { completion() }
    }

    /// Always re-encode the share-sheet image as JPEG. iOS Photos hands us
    /// HEIC bytes when the user is on "High Efficiency" storage, but we
    /// tell the backend the attachment is `image/jpeg` — sending HEIC
    /// payload with a JPEG mime makes Anthropic reject the request as
    /// malformed (showing up as `anthropic_failed (502)` from our backend).
    /// Cheap on modern devices and removes a whole class of failure modes.
    private func normalizeToJPEG(_ data: Data) -> Data {
        guard let image = UIImage(data: data) else {
            NSLog("[ShareExt] UIImage(data:) failed — falling back to raw bytes (size=%d)", data.count)
            return data
        }
        // Compression quality 0.85 stays under the App-Group / payload
        // budget for typical phone photos and is visually lossless for
        // anything the AI needs to inspect.
        let jpeg = image.jpegData(compressionQuality: 0.85) ?? data
        NSLog("[ShareExt] normalized image: in=%d out=%d size=%.0fx%.0f",
              data.count, jpeg.count, image.size.width, image.size.height)
        return jpeg
    }
}

// MARK: - State + SwiftUI

@MainActor
final class ShareModel: ObservableObject {
    @Published var text: String?
    @Published var urlString: String?
    @Published var imageData: Data?
    @Published var phase: Phase = .compose
    @Published var note: String = ""

    /// Running back-and-forth between user and Limor while the Share UI is
    /// still on screen. Starts with a single `.limor` turn after the first
    /// reply lands; each follow-up the user types appends one `.user` turn
    /// (optimistic) and one `.limor` turn (when the API returns).
    @Published var conversation: [Turn] = []
    /// True between "user tapped send on a follow-up" and "the new Limor
    /// turn lands". Drives the typing indicator under the latest user bubble
    /// in the conversation view.
    @Published var isReplying: Bool = false
    /// Draft for the inline follow-up composer. Held on the model so the
    /// view controller can clear it after a successful send.
    @Published var reply: String = ""

    var onSend: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onOpenApp: (() -> Void)?
    var onHandoffToApp: (() -> Void)?
    var onRetry: (() -> Void)?
    var onSendReply: ((String) -> Void)?
    var onDone: (() -> Void)?

    enum Phase: Equatable {
        case compose
        case sending
        /// Conversation is live — at least one Limor turn has landed and the
        /// user can keep replying inline. Replaces the old `.replied(String)`
        /// (which carried just the latest reply); the full thread now lives
        /// in `conversation`.
        case active
        case failed(message: String)
    }

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let text: String
        enum Role { case user, limor }
    }
}

private let limorIndigo = Color(red: 0.314, green: 0.275, blue: 0.898) // #504AE5

struct ShareComposeRoot: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .compose:
                ComposeView(model: model)
                    .transition(.opacity)
            case .sending:
                SendingView()
                    .transition(.opacity)
            case .active:
                ConversationView(model: model)
                    .transition(.opacity)
            case let .failed(message):
                FailedView(message: message, model: model)
                    .transition(.opacity)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .environment(\.layoutDirection, .rightToLeft)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }
}

// MARK: Compose phase

private struct ComposeView: View {
    @ObservedObject var model: ShareModel
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    noteField
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            Divider()
            sendBar
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: { model.onCancel?() }) {
                Text("ביטול")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("שיתוף ללימור")
                    .font(.headline)
                Text("יישלח לצ׳אט")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("ביטול").font(.body).opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var preview: some View {
        if let imageData = model.imageData, let uiImage = UIImage(data: imageData) {
            VStack(alignment: .leading, spacing: 6) {
                Text("תמונה")
                    .font(.caption).foregroundStyle(.secondary)
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.quaternary, lineWidth: 0.5)
                    )
            }
        } else if let url = model.urlString {
            sharedLinkRow(url)
        } else if let text = model.text {
            VStack(alignment: .leading, spacing: 6) {
                Text("טקסט משותף")
                    .font(.caption).foregroundStyle(.secondary)
                Text(text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
        }
    }

    private func sharedLinkRow(_ url: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(limorIndigo.opacity(0.12)).frame(width: 38, height: 38)
                Image(systemName: "link").foregroundStyle(limorIndigo)
            }
            Text(url)
                .font(.subheadline)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("הודעה ללימור")
                .font(.caption).foregroundStyle(.secondary)
            TextField(
                UserGender.pick(
                    male: "הוסף הקשר או שאלה (אופציונלי)",
                    female: "הוסיפי הקשר או שאלה (אופציונלי)"
                ),
                text: $model.note, axis: .vertical
            )
                .focused($noteFocused)
                .lineLimit(2...5)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .onAppear { noteFocused = true }
        }
    }

    private var sendBar: some View {
        Button {
            model.onSend?(model.note)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                Text("שלח ללימור")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(limorIndigo)
            )
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

// MARK: Sending phase

private struct SendingView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(limorIndigo)
            Text(UserGender.pick(male: "שולח ללימור…", female: "שולחת ללימור…"))
                .font(.headline)
                .foregroundStyle(.primary)
            Text(UserGender.pick(
                male: "תיכף תקבל תשובה ישר כאן",
                female: "תיכף תקבלי תשובה ישר כאן"
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Conversation phase

private struct ConversationView: View {
    @ObservedObject var model: ShareModel
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.conversation) { turn in
                            ConversationBubble(turn: turn)
                                .id(turn.id)
                        }
                        if model.isReplying {
                            HStack(spacing: 10) {
                                avatarBubble
                                TypingIndicator()
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .id("typing-indicator")
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }
                .onChange(of: model.conversation.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.isReplying) { _, _ in scrollToBottom(proxy) }
                .onAppear { scrollToBottom(proxy) }
            }
            Divider()
            replyComposer
            Divider()
            footerActions
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if model.isReplying {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            }
        } else if let last = model.conversation.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            VStack(spacing: 2) {
                Text("לימור ענתה")
                    .font(.headline)
                Text("נשמר בצ׳אט")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 14)
    }

    private var replyComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                UserGender.pick(male: "ענה ללימור…", female: "עני ללימור…"),
                text: $model.reply,
                axis: .vertical
            )
            .focused($replyFocused)
            .lineLimit(1...4)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .submitLabel(.send)

            Button(action: sendReply) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle().fill(canSend ? limorIndigo : limorIndigo.opacity(0.35))
                    )
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !model.isReplying &&
        !model.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendReply() {
        let trimmed = model.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !model.isReplying else { return }
        model.onSendReply?(trimmed)
    }

    private var footerActions: some View {
        HStack(spacing: 10) {
            Button { model.onOpenApp?() } label: {
                Text("פתח בצ׳אט")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(limorIndigo, lineWidth: 1)
                    )
                    .foregroundStyle(limorIndigo)
            }
            Button { model.onDone?() } label: {
                Text("סיימתי")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(limorIndigo)
                    )
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var avatarBubble: some View {
        ZStack {
            Circle()
                .fill(limorIndigo.opacity(0.15))
                .frame(width: 32, height: 32)
            Text("ל")
                .font(.headline)
                .foregroundStyle(limorIndigo)
        }
    }
}

private struct ConversationBubble: View {
    let turn: ShareModel.Turn

    var body: some View {
        // No `.frame(maxWidth: .infinity)` on the bubble itself — that was
        // forcing every message to stretch to the screen edge, including a
        // bubble that just said "12:00". Letting the bubble size to its
        // content (and using `Spacer(minLength:)` to push it to one side)
        // gives proper iMessage-style sizing: short replies are short
        // pills, long replies wrap naturally because the Spacer can shrink
        // to its minimum.
        HStack(alignment: .top, spacing: 10) {
            if turn.role == .limor {
                avatar
                limorBubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                userBubble
            }
        }
        .padding(.horizontal, 16)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(limorIndigo.opacity(0.15)).frame(width: 32, height: 32)
            Text("ל").font(.headline).foregroundStyle(limorIndigo)
        }
    }

    private var limorBubble: some View {
        Text(LocalizedStringKey(turn.text))
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(limorIndigo.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(limorIndigo.opacity(0.20), lineWidth: 0.5)
            )
            .textSelection(.enabled)
    }

    private var userBubble: some View {
        Text(turn.text)
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(limorIndigo)
            )
            .textSelection(.enabled)
    }
}

private struct TypingIndicator: View {
    @State private var dot: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(limorIndigo.opacity(dot == i ? 0.9 : 0.35))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(limorIndigo.opacity(0.10))
        )
        .onAppear {
            // Repeating timer cycling which dot is highlighted gives the
            // classic "…" rhythm without needing a custom Animation.
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                dot = (dot + 1) % 3
            }
        }
    }
}

// MARK: Failed phase

private struct FailedView: View {
    let message: String
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("הבקשה לא נשלחה ללימור")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 10) {
                Button { model.onRetry?() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text(UserGender.pick(male: "נסה שוב", female: "נסי שוב"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(limorIndigo)
                    )
                    .foregroundStyle(.white)
                }
                HStack(spacing: 10) {
                    Button { model.onDone?() } label: {
                        Text("סגור")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(.secondary, lineWidth: 1)
                            )
                            .foregroundStyle(.primary)
                    }
                    Button { model.onHandoffToApp?() } label: {
                        Text("פתח באפליקציה")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(limorIndigo, lineWidth: 1)
                            )
                            .foregroundStyle(limorIndigo)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}
