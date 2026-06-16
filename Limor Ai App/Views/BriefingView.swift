import SwiftUI
import MessageUI

extension Notification.Name {
    /// Posted when the background investor-update generation finishes (driven
    /// by the `briefing_ready` push). An open BriefingView re-fetches on it.
    static let limorBriefingReady = Notification.Name("limorBriefingReady")
}

// MARK: - Home card

/// "תקציר מנהלים" — entry point to the investor-grade Executive Business
/// Update. Shows when the last update was generated; tapping opens the full
/// formatted email with Generate + Send buttons. Heavy on-demand feature.
struct BriefingCard: View {
    @State private var briefing: CeoBriefing?
    @State private var loadedOnce = false

    private var tint: Color { HomeCardKind.briefing.tint }

    var body: some View {
        NavigationLink {
            BriefingDetailView(initial: briefing)
        } label: {
            GlassCard(tint: tint) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(icon: HomeCardKind.briefing.icon, title: tr("תקציר מנהלים", "Executive Briefing"), tint: tint)
                        Spacer()
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                    }
                    if briefing?.isGenerating == true {
                        HStack(spacing: 8) {
                            ProgressView().tint(tint)
                            Text(tr("מכינה את התקציר ברקע…", "Preparing your briefing in the background…"))
                                .font(.subheadline).foregroundStyle(.limorMuted)
                        }
                    } else if let b = briefing, b.hasData {
                        Text(b.subject ?? "Executive Business Update")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.limorInk)
                            .lineLimit(2)
                        Text(metaLine(b))
                            .font(.caption2)
                            .foregroundStyle(.limorMuted)
                    } else {
                        Text(tr("עדכון עסקי בנוסח דוח למשקיעים — מבוסס על המייל שלך, מוכן לשליחה. הקש להפקה.", "An investor-style business update — based on your email, ready to send. Tap to generate."))
                            .font(.subheadline)
                            .foregroundStyle(.limorMuted)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .limorBriefingReady)) { _ in
            Task { briefing = try? await APIClient.shared.getBriefing() }
        }
    }

    private func metaLine(_ b: CeoBriefing) -> String {
        var parts: [String] = []
        if let n = b.email_count { parts.append(tr("\(n) מיילים", "\(n) emails")) }
        if let iso = b.generated_at,
           let d = ISO8601DateFormatter.limor.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) {
            let f = RelativeDateTimeFormatter()
            f.locale = Locale(identifier: "he_IL")
            parts.append(tr("עודכן \(f.localizedString(for: d, relativeTo: Date()))", "Updated \(f.localizedString(for: d, relativeTo: Date()))"))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard !loadedOnce else { return }
        if DemoMode.isOn { briefing = DemoData.briefing; loadedOnce = true; return }
        briefing = try? await APIClient.shared.getBriefing()
        loadedOnce = true
    }
}

// MARK: - Detail screen

struct BriefingDetailView: View {
    var initial: CeoBriefing?

    @State private var briefing: CeoBriefing?
    @State private var generating = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var showMail = false
    @State private var showShare = false
    @AppStorage("limor.briefingLang") private var lang: String = "he"

    private var tint: Color { HomeCardKind.briefing.tint }
    private var b: CeoBriefing? { briefing ?? initial }
    private var isGenerating: Bool { generating || (b?.isGenerating ?? false) }

    var body: some View {
        ZStack {
            LiquidBackdrop().ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    langPicker
                    generateButton

                    if isGenerating { progressCard }

                    if let errorMessage {
                        GlassCard {
                            Text(errorMessage).font(.subheadline).foregroundStyle(.limorCoral)
                        }
                    }

                    if let b, b.hasData {
                        if let subject = b.subject, !subject.isEmpty {
                            HStack {
                                Text(subject)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.limorInk)
                                    .environment(\.layoutDirection, .leftToRight)
                                Spacer(minLength: 0)
                            }
                        }
                        sendButtons(b)
                        GlassCard {
                            HTMLText(html: b.html_body ?? "")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if loaded && !isGenerating {
                        GlassCard {
                            Text(tr("עוד לא הופק תקציר. הקש על \"הפק תקציר\" ולימור תכין עדכון עסקי בנוסח דוח למשקיעים מהשבוע האחרון. אפשר לצאת מהמסך — נודיע לך כשמוכן.", "No briefing yet. Tap \"Generate Briefing\" and Limor will prepare an investor-style business update from the past week. You can leave this screen — we'll let you know when it's ready."))
                                .font(.subheadline).foregroundStyle(.limorMuted)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle(tr("תקציר מנהלים", "Executive Briefing"))
        .navigationBarTitleDisplayMode(.large)
        .onReceive(NotificationCenter.default.publisher(for: .limorBriefingReady)) { _ in
            Task { await refetch() }
        }
        .sheet(isPresented: $showMail) {
            if let b {
                MailComposeView(subject: b.subject ?? "Executive Business Update",
                                htmlBody: b.html_body ?? "")
            }
        }
        .sheet(isPresented: $showShare) {
            if let b {
                // Plain-text fallback share (loses formatting) — for non-mail apps.
                ShareSheet(items: [plainText(b)])
            }
        }
        .task {
            if DemoMode.isOn { briefing = DemoData.briefing; loaded = true; return }
            if briefing == nil { briefing = try? await APIClient.shared.getBriefing() }
            loaded = true
        }
    }

    @ViewBuilder
    private func sendButtons(_ b: CeoBriefing) -> some View {
        HStack(spacing: 10) {
            if MFMailComposeViewController.canSendMail() {
                Button {
                    showMail = true
                } label: {
                    Label(tr("שליחה במייל", "Send by email"), systemImage: "envelope.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.14)))
                        .foregroundStyle(tint)
                }
            }
            Button {
                showShare = true
            } label: {
                Label(tr("שיתוף", "Share"), systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.limorInk.opacity(0.06)))
                    .foregroundStyle(.limorInk)
            }
        }
    }

    private var langPicker: some View {
        Picker(tr("שפה", "Language"), selection: $lang) {
            Text(tr("עברית", "Hebrew")).tag("he")
            Text("English").tag("en")
        }
        .pickerStyle(.segmented)
        .disabled(isGenerating)
    }

    private var generateButton: some View {
        Button {
            Task { await generate() }
        } label: {
            HStack {
                Image(systemName: "sparkles")
                Text(b?.hasData == true ? tr("רענן תקציר", "Refresh briefing") : tr("הפק תקציר", "Generate briefing"))
            }
            .font(.headline)
        }
        .buttonStyle(LimorPrimaryButtonStyle())
        .disabled(isGenerating)
    }

    private var progressCard: some View {
        GlassCard(tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().tint(tint)
                    Text(tr("לימור עוברת על המייל ומכינה את העדכון…", "Limor is going through your email and preparing the update…"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.limorInk)
                }
                ProgressView().progressViewStyle(.linear).tint(tint)
                Text(tr("אפשר לצאת מהמסך — נשלח לך התראה ברגע שמוכן.", "You can leave this screen — we'll send you a notification the moment it's ready."))
                    .font(.caption).foregroundStyle(.limorMuted)
            }
        }
    }

    /// Kick off generation. The server returns immediately and runs the heavy
    /// pass in the background; the ready-push (or the poll) delivers the result.
    private func generate() async {
        if DemoMode.isOn { briefing = DemoData.briefing; return }
        generating = true
        errorMessage = nil
        do {
            _ = try await APIClient.shared.refreshBriefing(lang: lang)
            await refetch()      // doc now carries status=generating
            startPolling()
        } catch {
            errorMessage = tr("ההפקה נכשלה — נסו שוב (\(error.localizedDescription))", "Generation failed — please try again (\(error.localizedDescription))")
        }
        generating = false
    }

    private func startPolling() {
        Task {
            for _ in 0..<40 {   // ~3.5 min ceiling
                try? await Task.sleep(for: .seconds(5))
                guard let fresh = try? await APIClient.shared.getBriefing() else { continue }
                if fresh.status != "generating" {
                    briefing = fresh
                    if fresh.status == "error" { errorMessage = tr("ההפקה נכשלה — נסו שוב.", "Generation failed — please try again.") }
                    return
                }
                briefing = fresh
            }
        }
    }

    private func refetch() async {
        if let fresh = try? await APIClient.shared.getBriefing() { briefing = fresh }
    }

    /// A readable plain-text rendering for the non-mail share sheet (strips
    /// HTML tags). Mail keeps full formatting via the composer.
    private func plainText(_ b: CeoBriefing) -> String {
        let stripped = (b.html_body ?? "")
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "</h2>", with: "\n")
            .replacingOccurrences(of: "</h3>", with: "\n")
            .replacingOccurrences(of: "</li>", with: "\n")
            .replacingOccurrences(of: "<li", with: "• <li")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        let lines = stripped.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return ((b.subject ?? "Executive Business Update") + "\n\n" +
                lines.joined(separator: "\n"))
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }
}

// MARK: - HTML rendering

/// Renders backend HTML (the investor email) as formatted, selectable text.
/// A non-editable UITextView with an HTML-derived attributed string — keeps
/// headings/bold/lists and is copy-able. Content is English, so LTR.
private struct HTMLText: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        // Wrap to the view's width instead of laying out at the HTML's natural
        // (very wide) width — that overflow was the broken display.
        tv.textContainer.widthTracksTextView = true
        // Let the HTML's own dir attribute decide LTR (English) vs RTL (Hebrew)
        // alignment instead of forcing one direction.
        tv.textAlignment = .natural
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        guard let data = html.data(using: .utf8) else { return }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let attr = try? NSMutableAttributedString(data: data, options: opts, documentAttributes: nil) {
            // Normalize to the app's text color so it reads in light/dark.
            attr.addAttribute(.foregroundColor, value: UIColor.label,
                              range: NSRange(location: 0, length: attr.length))
            tv.attributedText = attr
        }
    }

    /// Constrain the text view to the proposed width and report the height it
    /// needs — without this SwiftUI gave it the HTML's huge intrinsic width and
    /// the content bled past the card.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width - 72
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fit.height)
    }
}

// MARK: - Mail composer

/// Opens the system mail composer with the investor update as an HTML body —
/// formatting (headings, bold, lists) is preserved in the sent email.
private struct MailComposeView: UIViewControllerRepresentable {
    let subject: String
    let htmlBody: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setSubject(subject)
        vc.setMessageBody(htmlBody, isHTML: true)
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            dismiss()
        }
    }
}

// (Plain share sheet uses the shared `ShareSheet` defined in AdminBillingView.swift.)
