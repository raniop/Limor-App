import SwiftUI
import UIKit

// MARK: - Urgency display helpers

extension EmailUrgency {
    var label: String {
        switch self {
        case .critical: return tr("קריטי", "Critical")
        case .high:     return tr("גבוה", "High")
        case .medium:   return tr("השבוע", "This week")
        case .low:      return tr("לא דחוף", "Not urgent")
        }
    }

    var color: Color {
        switch self {
        case .critical: return .limorDanger
        case .high:     return .limorWarning
        case .medium:   return .limorIndigo
        case .low:      return .limorMuted
        }
    }

    /// Ordering for sorting — critical first.
    var rank: Int {
        switch self {
        case .critical: return 0
        case .high:     return 1
        case .medium:   return 2
        case .low:      return 3
        }
    }
}

// MARK: - Home card

/// Compact home-screen card for the executive email report — shows how many
/// things need attention and a preview of the top items. Taps into the full
/// `EmailActionsView`. Reads the cached report; the server-side refresh
/// (24h cooldown) is kicked off by `SyncManager` after every email sync.
struct EmailActionsCard: View {
    @ObservedObject private var sync = SyncManager.shared
    @State private var report: EmailActionReport?
    @State private var loadedOnce = false

    // Filter out items the user marked "handled" — read fresh from SharedStore
    // each render so a dismissal in the detail screen reflects on return.
    private func notDismissed<T>(_ items: [T], key: (T) -> String) -> [T] {
        let hidden = SharedStore.dismissedEmailActionKeys
        return items.filter { !hidden.contains(key($0)) }
    }
    private var visibleTop: [EmailActionItem] {
        notDismissed(report?.top_items ?? []) { $0.dismissKey }
    }
    private var visibleAdditional: [EmailActionItem] {
        notDismissed(report?.additional_items ?? []) { $0.dismissKey }
    }
    private var visibleFollowUps: [EmailFollowUp] {
        notDismissed(report?.follow_ups ?? []) { $0.dismissKey }
    }
    private var totalActions: Int { visibleTop.count + visibleAdditional.count }
    private var nothingToShow: Bool {
        visibleTop.isEmpty && visibleAdditional.isEmpty && visibleFollowUps.isEmpty
            && (report?.risks.isEmpty ?? true) && (report?.todo.isEmpty ?? true)
    }

    var body: some View {
        NavigationLink(destination: EmailActionsView()) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(icon: "tray.full.fill", title: tr("מוקד המייל", "Email hub"), tint: .limorViolet)
                        Spacer()
                        if totalActions > 0 {
                            Text("\(totalActions)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.limorViolet)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.limorViolet.opacity(0.12)))
                        }
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                    }

                    if report != nil {
                        if report?.generated_at == nil {
                            // On-demand: nothing generated yet — invite a tap.
                            tapToGenerateRow
                        } else if nothingToShow {
                            emptyRow
                        } else {
                            VStack(spacing: 6) {
                                ForEach(visibleTop.prefix(3)) { item in
                                    CompactActionRow(item: item)
                                }
                            }
                            if visibleFollowUps.count > 0 || (report?.risks.count ?? 0) > 0 {
                                footerHint(followUps: visibleFollowUps.count, risks: report?.risks.count ?? 0)
                            }
                        }
                    } else if loadedOnce {
                        tapToGenerateRow
                    } else {
                        loadingRow
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task { await load() }
        .onChange(of: sync.lastEmailActionsRefresh) { _, _ in Task { await load() } }
    }

    private func load() async {
        report = try? await APIClient.shared.getEmailActions()
        loadedOnce = true
    }

    private func footerHint(followUps: Int, risks: Int) -> some View {
        HStack(spacing: 12) {
            if followUps > 0 {
                Label(tr("\(followUps) פולואפים", "\(followUps) follow-ups"), systemImage: "arrowshape.turn.up.left.fill")
            }
            if risks > 0 {
                Label(tr("\(risks) סיכונים", "\(risks) risks"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.limorWarning)
            }
            Spacer()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.limorMuted)
        .padding(.top, 2)
    }

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.caption).foregroundStyle(.limorSuccess)
            Text(tr("הכול תחת שליטה — אין מיילים שדורשים טיפול", "All under control — no emails need handling")).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// On-demand: prompt the user to open + generate the report.
    private var tapToGenerateRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.caption).foregroundStyle(.limorViolet)
            Text(tr("הקש כדי שלימור תעבור על המייל ותכין לך את מוקד המשימות", "Tap and Limor will go through your inbox and prepare your action hub")).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.limorViolet).scaleEffect(0.7)
            Text(tr("סורק את המייל…", "Scanning your inbox…")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One-line preview row used on the home card.
private struct CompactActionRow: View {
    let item: EmailActionItem

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(item.urgency.color).frame(width: 7, height: 7)
            Text(item.required_action)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.limorInk)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(item.sender_name)
                .font(.caption2)
                .foregroundStyle(.limorMuted)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Account attribution

/// A connected email account referenced by the report's items.
struct AccountRef: Hashable {
    let email: String
    let provider: String?
}

/// Brand-ish tint per provider so Gmail vs Outlook read at a glance.
func providerTint(_ provider: String?) -> Color {
    switch provider {
    case "google":    return .red
    case "microsoft": return .blue
    default:          return .limorViolet
    }
}

/// Small chip on each item showing which account the email arrived in
/// (icon + address). Renders nothing when no account is known.
struct AccountBadge: View {
    let provider: String?
    let account: String?

    private var label: String? {
        if let account, !account.isEmpty { return account }
        switch provider {
        case "google":    return "Gmail"
        case "microsoft": return "Outlook"
        default:          return nil
        }
    }

    var body: some View {
        if let label {
            HStack(spacing: 4) {
                Image(systemName: "envelope.fill").font(.system(size: 9))
                Text(label).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(providerTint(provider))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(providerTint(provider).opacity(0.12)))
        }
    }
}

/// Limor's suggested reply, with a one-tap copy button (and manual text
/// selection). Lets the user lift the drafted response straight into their
/// mail/WhatsApp without retyping.
struct SuggestedReplyBox: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.caption2).foregroundStyle(.limorViolet)
                Text(tr("תשובה מוצעת", "Suggested reply"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.limorViolet)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(.easeInOut(duration: 0.15)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation(.easeInOut(duration: 0.15)) { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? tr("הועתק", "Copied") : tr("העתק", "Copy"))
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(copied ? .limorSuccess : .limorViolet)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill((copied ? Color.limorSuccess : Color.limorViolet).opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.limorInk)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.limorViolet.opacity(0.08)))
    }
}

// MARK: - Full report screen

struct EmailActionsView: View {
    @State private var report: EmailActionReport?
    @State private var loaded = false
    @State private var refreshing = false
    @State private var addedReminderItemIds: Set<String> = []
    @State private var errorMessage: String?
    @State private var dismissed: Set<String> = SharedStore.dismissedEmailActionKeys
    /// Action item the user tapped "שתף" on — opens the share sheet with
    /// this item pre-selected (more items can be added there).
    @State private var sharingItem: EmailActionItem?
    // Active account filter (nil = all accounts). Only surfaces when the user
    // has items from more than one connected account.
    @State private var accountFilter: String? = nil
    // Refresh progress (Sonnet over the inbox takes ~30–60s, so we show a
    // smoothly-creeping bar that snaps to 100% the moment it's ready).
    @State private var progress: Double = 0
    @State private var showProgressBar = false

    // Items the user marked "handled" are filtered out everywhere. When an
    // account filter is active, only items from that account remain.
    private func matchesFilter(_ email: String?) -> Bool {
        guard let accountFilter else { return true }
        return email == accountFilter
    }
    private var visibleTop: [EmailActionItem] {
        (report?.top_items ?? []).filter { !dismissed.contains($0.dismissKey) && matchesFilter($0.account_email) }
    }
    private var visibleAdditional: [EmailActionItem] {
        (report?.additional_items ?? []).filter { !dismissed.contains($0.dismissKey) && matchesFilter($0.account_email) }
    }
    private var visibleFollowUps: [EmailFollowUp] {
        (report?.follow_ups ?? []).filter { !dismissed.contains($0.dismissKey) && matchesFilter($0.account_email) }
    }

    /// Distinct connected accounts that appear in this report, for the filter
    /// chips. Computed from the full report so chips stay stable as items are
    /// dismissed or filtered.
    private var presentAccounts: [AccountRef] {
        var seen: [String: AccountRef] = [:]
        func add(_ provider: String?, _ email: String?) {
            guard let email, !email.isEmpty, seen[email] == nil else { return }
            seen[email] = AccountRef(email: email, provider: provider)
        }
        (report?.top_items ?? []).forEach { add($0.provider, $0.account_email) }
        (report?.additional_items ?? []).forEach { add($0.provider, $0.account_email) }
        (report?.follow_ups ?? []).forEach { add($0.provider, $0.account_email) }
        return seen.values.sorted { $0.email < $1.email }
    }
    private var allHidden: Bool {
        visibleTop.isEmpty && visibleAdditional.isEmpty && visibleFollowUps.isEmpty
            && (report?.risks.isEmpty ?? true) && (report?.todo.isEmpty ?? true)
    }

    private func dismiss(_ key: String) {
        dismissed.insert(key)
        SharedStore.dismissedEmailActionKeys = dismissed
    }

    var body: some View {
        ZStack {
            LiquidBackdrop()
            content
        }
        .overlay(alignment: .top) {
            if showProgressBar { progressBanner }
        }
        .animation(.easeInOut(duration: 0.3), value: showProgressBar)
        .navigationTitle(tr("מוקד המייל", "Email hub"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh(force: true) } } label: {
                    if refreshing {
                        ProgressView().tint(.limorViolet)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.limorViolet)
                    }
                }
                .disabled(refreshing)
            }
        }
        .task { await load() }
        .sheet(item: $sharingItem) { item in
            ShareTasksSheet(
                initialItem: item,
                allItems: ((report?.top_items ?? []) + (report?.additional_items ?? []))
                    .filter { !dismissed.contains($0.dismissKey) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(tr("שגיאה", "Error"), isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(tr("אוקיי", "OK"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        if let report {
            if allHidden {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if presentAccounts.count > 1 {
                            accountFilterBar
                        }
                        if !visibleTop.isEmpty {
                            section(title: tr("החשובים ביותר", "Most important"), icon: "star.fill", tint: .limorViolet) {
                                ForEach(visibleTop) { item in actionCard(item) }
                            }
                        }
                        if !visibleAdditional.isEmpty {
                            section(title: tr("פעולות נוספות", "More actions"), icon: "list.bullet", tint: .limorIndigo) {
                                ForEach(visibleAdditional) { item in actionCard(item) }
                            }
                        }
                        if !visibleFollowUps.isEmpty {
                            section(title: tr("פולואפים שכדאי לשלוח", "Follow-ups worth sending"), icon: "arrowshape.turn.up.left.fill", tint: .limorMint) {
                                ForEach(visibleFollowUps) { f in followUpCard(f) }
                            }
                        }
                        if !report.risks.isEmpty {
                            section(title: tr("סיכונים ודברים שאולי מתפספסים", "Risks and things that might slip"), icon: "exclamationmark.triangle.fill", tint: .limorWarning) {
                                ForEach(Array(report.risks.enumerated()), id: \.offset) { _, r in
                                    bulletRow(r, tint: .limorWarning)
                                }
                            }
                        }
                        if !report.todo.isEmpty {
                            section(title: tr("סדר העדיפויות שלך", "Your priority order"), icon: "checklist", tint: .limorIndigo) {
                                ForEach(Array(report.todo.enumerated()), id: \.offset) { idx, t in
                                    numberedRow(index: idx + 1, text: t)
                                }
                            }
                        }
                        if let stamp = generatedLabel(report.generated_at) {
                            Text(stamp)
                                .font(.caption2)
                                .foregroundStyle(.limorMuted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .limorReadableWidth()
                }
                .refreshable { await refresh(force: true) }
            }
        } else if loaded {
            emptyState
        } else {
            ProgressView().tint(.limorViolet)
        }
    }

    // MARK: Account filter

    private var accountFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: tr("הכול", "All"), icon: "tray.full.fill", provider: nil, value: nil)
                ForEach(presentAccounts, id: \.email) { acct in
                    filterChip(label: acct.email, icon: "envelope.fill", provider: acct.provider, value: acct.email)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func filterChip(label: String, icon: String, provider: String?, value: String?) -> some View {
        let selected = accountFilter == value
        let tint = providerTint(provider)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { accountFilter = value }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(.caption.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? .white : tint)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selected ? tint : tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Sections + rows

    @ViewBuilder
    private func section<C: View>(title: String, icon: String, tint: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(icon: icon, title: title, tint: tint)
            content()
        }
    }

    private func actionCard(_ item: EmailActionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UrgencyBadge(urgency: item.urgency)
                Text(tr("חשיבות \(item.importance)/10", "Importance \(item.importance)/10"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.limorMuted)
                if item.needs_review {
                    Text(tr("לבדיקה", "Review"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.limorWarning)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.limorWarning.opacity(0.14)))
                }
                Spacer()
                AccountBadge(provider: item.provider, account: item.account_email)
            }

            Text(item.required_action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.limorInk)

            HStack(spacing: 6) {
                Image(systemName: "person.fill").font(.caption2)
                Text(senderLine(item))
            }
            .font(.caption)
            .foregroundStyle(.limorMuted)

            if !item.subject.isEmpty {
                Text(tr("נושא: \(item.subject)", "Subject: \(item.subject)"))
                    .font(.caption)
                    .foregroundStyle(.limorMuted)
                    .lineLimit(2)
            }

            if !item.why.isEmpty {
                Text(item.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let suggestion = item.suggested_response, !suggestion.isEmpty {
                SuggestedReplyBox(text: suggestion)
            }

            HStack(spacing: 8) {
                reminderButton(item)
                shareButton(item)
                handledButton(item.dismissKey)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(item.urgency.color.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func reminderButton(_ item: EmailActionItem) -> some View {
        let added = addedReminderItemIds.contains(item.id)
        Button {
            Task { await createReminder(from: item) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: added ? "checkmark.circle.fill" : "bell.badge.fill")
                Text(added ? tr("נוספה תזכורת", "Reminder added") : tr("צור תזכורת", "Create reminder"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(added ? .limorSuccess : .white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Capsule().fill(added ? Color.limorSuccess.opacity(0.15) : Color.limorViolet)
            )
        }
        .buttonStyle(.plain)
        .disabled(added)
        .padding(.top, 2)
    }

    /// "Share" — hand this action item (and optionally more from the current
    /// report) to another Limor user as tasks in THEIR task list.
    private func shareButton(_ item: EmailActionItem) -> some View {
        Button {
            sharingItem = item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                Text(tr("שתף", "Share"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.limorIndigo)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// "Handled" — hide this item locally so it stops surfacing (survives the
    /// daily regeneration via the stable dismiss key).
    private func handledButton(_ key: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { dismiss(key) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                Text(tr("טופל", "Handled"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.limorMuted)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.limorMuted.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func followUpCard(_ f: EmailFollowUp) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption)
                .foregroundStyle(.limorMint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.person).font(.subheadline.weight(.semibold)).foregroundStyle(.limorInk)
                Text(f.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AccountBadge(provider: f.provider, account: f.account_email)
                    .padding(.top, 1)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { dismiss(f.dismissKey) }
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bulletRow(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(tint).padding(.top, 6)
            Text(text).font(.subheadline).foregroundStyle(.limorInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func numberedRow(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.limorIndigo))
            Text(text).font(.subheadline).foregroundStyle(.limorInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.full")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.limorMuted)
            Text(tr("הכול תחת שליטה", "All under control"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.limorInk)
            Text(tr("אין כרגע מיילים שדורשים פעולה, החלטה או פולואפ.", "No emails right now that need an action, a decision, or a follow-up."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: Data

    private func load() async {
        report = try? await APIClient.shared.getEmailActions()
        loaded = true
    }

    // MARK: Progress bar

    private var progressBanner: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.limorViolet)
                Text(progress >= 1 ? tr("מוכן ✨", "Ready ✨") : tr("לימור עוברת על המייל…", "Limor is going through your inbox…"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.limorViolet)
            }
            ProgressView(value: progress).tint(.limorViolet)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.limorViolet.opacity(0.2)))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Smoothly creep the bar toward ~92% while the refresh runs (asymptotic,
    /// so it slows as it goes — honest about "almost there but waiting"), then
    /// snap to 100% the moment the result lands.
    private func runProgress() async {
        progress = 0
        showProgressBar = true
        let start = Date()
        while refreshing {
            let elapsed = Date().timeIntervalSince(start)
            progress = min(0.92, 1 - exp(-elapsed / 18))
            try? await Task.sleep(for: .milliseconds(150))
        }
        withAnimation(.easeOut(duration: 0.3)) { progress = 1.0 }
        try? await Task.sleep(for: .milliseconds(650))
        showProgressBar = false
    }

    private func refresh(force: Bool) async {
        guard !refreshing else { return }   // ignore a second tap mid-refresh
        refreshing = true
        defer { refreshing = false }
        let progressTask = Task { await runProgress() }
        defer { _ = progressTask }
        // Run the (often 30-60s Sonnet) regen in an UNSTRUCTURED task so that
        // SwiftUI cancelling the pull-to-refresh gesture's task doesn't abort
        // the request — that was surfacing a bogus "cancelled" error alert.
        // The work finishes server-side regardless and we pick up the result.
        let work = Task { try await APIClient.shared.refreshEmailActions(force: force) }
        do {
            report = try await work.value
            loaded = true
        } catch is CancellationError {
            // Gesture/task cancelled — not a real error, say nothing.
        } catch let error as URLError where error.code == .cancelled {
            // Same — a cancelled request isn't worth an alert.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createReminder(from item: EmailActionItem) async {
        let due = item.urgency.suggestedDueDate()
        do {
            _ = try await APIClient.shared.createReminder(token: "", task: item.required_action, dueAt: due)
            addedReminderItemIds.insert(item.id)
            // Re-arm the on-device schedule so the new reminder picks up the
            // at-due push + the 2h-before heads-up immediately.
            await LeadTimeNotifier.reschedule()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func senderLine(_ item: EmailActionItem) -> String {
        if let company = item.company, !company.isEmpty {
            return "\(item.sender_name) · \(company)"
        }
        return item.sender_name
    }

    private func generatedLabel(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter.limor.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "he_IL")
        f.dateFormat = "d.M HH:mm"
        return tr("עודכן \(f.string(from: date))", "Updated \(f.string(from: date))")
    }
}

// MARK: - Urgency badge

private struct UrgencyBadge: View {
    let urgency: EmailUrgency
    var body: some View {
        Text(urgency.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(urgency.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(urgency.color.opacity(0.14)))
    }
}

// MARK: - Share tasks sheet

/// Share Email-Hub action items with another Limor user: the tapped item
/// arrives pre-selected, the rest of the current report can be added with a
/// tap, the recipient is entered by email (the address their Limor account
/// uses). Each selected item lands as a task in the recipient's task list,
/// plus a push so they notice.
private struct ShareTasksSheet: View {
    let initialItem: EmailActionItem
    let allItems: [EmailActionItem]
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIds: Set<String>
    @State private var email = ""
    @State private var sending = false
    @State private var resultMessage: String?
    @State private var failed = false
    /// Shown on the "no Limor account" result so the user can fall back to
    /// a regular email in one tap.
    @State private var offerEmailFallback = false
    /// Colleagues from the user's company — one-tap recipient chips.
    @State private var colleagues: [APIClient.OrgMember] = []
    @Environment(\.openURL) private var openURL

    init(initialItem: EmailActionItem, allItems: [EmailActionItem]) {
        self.initialItem = initialItem
        self.allItems = allItems
        _selectedIds = State(initialValue: [initialItem.id])
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var emailValid: Bool {
        trimmedEmail.contains("@") && trimmedEmail.contains(".")
    }

    var body: some View {
        NavigationStack {
            // LiquidBackdrop as .background (NOT a ZStack sibling) — its
            // oversized decorative blobs were inflating the ZStack's width,
            // which pushed the whole sheet content past the screen edge and
            // let it drift sideways. A background never affects layout.
            ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        if let resultMessage {
                            VStack(spacing: 12) {
                                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(failed ? Color.limorWarning : Color.limorSuccess)
                                Text(resultMessage)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.limorInk)
                                    .multilineTextAlignment(.center)
                                if offerEmailFallback {
                                    Button {
                                        openMailCompose()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "envelope.fill")
                                            Text(tr("שלח במייל רגיל", "Send by regular email"))
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.limorPrimary)
                                }
                                Button(tr("סגור", "Close")) { dismiss() }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.limorMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            SectionLabel(icon: "person.badge.plus", title: tr("למי לשלוח?", "Send to whom?"))
                            TextField(tr("המייל של המשתמש בלימור", "Their Limor account email"), text: $email)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.limorInk.opacity(0.06)))

                            // Company colleagues — one tap fills the address.
                            if !colleagues.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(colleagues, id: \.email) { member in
                                            let isChosen = trimmedEmail == member.email.lowercased()
                                            Button {
                                                email = member.email
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "person.crop.circle.fill")
                                                        .font(.caption)
                                                    Text(member.display_name?.isEmpty == false ? member.display_name! : member.email)
                                                        .font(.caption.weight(.semibold))
                                                        .lineLimit(1)
                                                }
                                                .foregroundStyle(isChosen ? .white : .limorIndigo)
                                                .padding(.horizontal, 12).padding(.vertical, 7)
                                                .background(Capsule().fill(isChosen ? Color.limorIndigo : Color.limorIndigo.opacity(0.10)))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }

                            // Primary actions live at the TOP — no scrolling
                            // past a long task list just to hit "share".
                            Button {
                                Task { await share() }
                            } label: {
                                HStack {
                                    if sending { ProgressView().tint(.white) }
                                    Text(sending
                                         ? tr("שולח…", "Sending…")
                                         : tr("שתף \(selectedIds.count) משימות", "Share \(selectedIds.count) tasks"))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.limorPrimary)
                            .disabled(sending || selectedIds.isEmpty || !emailValid)

                            Button {
                                openMailCompose()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "envelope")
                                    Text(tr("או: שלח במייל רגיל (לכל כתובת)", "Or: send by regular email (any address)"))
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.limorIndigo)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Capsule().fill(Color.limorIndigo.opacity(0.10)))
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedIds.isEmpty)

                            SectionLabel(icon: "checklist", title: tr("אילו משימות לשתף?", "Which tasks to share?"))
                            VStack(spacing: 8) {
                                ForEach(allItems) { item in
                                    let selected = selectedIds.contains(item.id)
                                    Button {
                                        if selected { selectedIds.remove(item.id) }
                                        else { selectedIds.insert(item.id) }
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                .font(.title3)
                                                .foregroundStyle(selected ? Color.limorIndigo : Color.limorMuted)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.required_action)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.limorInk)
                                                    .multilineTextAlignment(.leading)
                                                    .lineLimit(2)
                                                    .fixedSize(horizontal: false, vertical: true)
                                                Text(item.sender_name)
                                                    .font(.caption)
                                                    .foregroundStyle(.limorMuted)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(selected ? Color.limorIndigo.opacity(0.08) : Color.limorInk.opacity(0.03))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LiquidBackdrop().ignoresSafeArea())
            .task {
                colleagues = (try? await APIClient.shared.getOrgMembers()) ?? []
            }
            .navigationTitle(tr("שיתוף משימות", "Share tasks"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("ביטול", "Cancel")) { dismiss() }
                        .foregroundStyle(.limorMuted)
                }
            }
        }
    }

    /// Open the system mail composer (mailto:) pre-filled with the selected
    /// tasks — the fallback/alternative that reaches ANY address, sent from
    /// the user's own mail account. No extra permissions needed.
    private func openMailCompose() {
        let selected = allItems.filter { selectedIds.contains($0.id) }
        let subject = selected.count == 1
            ? tr("משימה: \(selected[0].required_action)", "Task: \(selected[0].required_action)")
            : tr("\(selected.count) משימות בשבילך", "\(selected.count) tasks for you")

        // Proper paragraphs, not one dense blob: greeting, then each task as
        // a numbered block (action on its own line, source context indented
        // under it), blank line between blocks, sign-off at the end.
        var paragraphs: [String] = [
            tr("שלום,", "Hi,"),
            selected.count == 1
                ? tr("רציתי להעביר אליך את המשימה הבאה:", "I wanted to pass this task on to you:")
                : tr("רציתי להעביר אליך את המשימות הבאות:", "I wanted to pass these tasks on to you:"),
        ]
        for (idx, item) in selected.enumerated() {
            var block = "\(idx + 1). \(item.required_action)"
            var contextParts: [String] = []
            if !item.sender_name.isEmpty {
                contextParts.append(tr("מקור: \(item.sender_name)", "Source: \(item.sender_name)"))
            }
            if !item.subject.isEmpty {
                contextParts.append(tr("נושא: \"\(item.subject)\"", "Subject: \"\(item.subject)\""))
            }
            if !contextParts.isEmpty {
                block += "\n    " + contextParts.joined(separator: " · ")
            }
            paragraphs.append(block)
        }
        paragraphs.append(tr("תודה!", "Thanks!"))
        paragraphs.append(tr("— נשלח דרך לימור", "— Sent via Limor"))
        let body = paragraphs.joined(separator: "\n\n")

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailValid ? trimmedEmail : ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url {
            openURL(url)
        }
    }

    private func share() async {
        sending = true
        defer { sending = false }
        let titles = allItems.filter { selectedIds.contains($0.id) }.map { $0.required_action }
        do {
            let result = try await APIClient.shared.shareTasks(titles: titles, emails: [trimmedEmail])
            if result.shared.isEmpty {
                failed = true
                resultMessage = tr(
                    "לכתובת \(trimmedEmail) אין חשבון לימור. אפשר במקום זה לשלוח את המשימות במייל רגיל 👇",
                    "\(trimmedEmail) has no Limor account. You can send the tasks by regular email instead 👇"
                )
                offerEmailFallback = true
            } else {
                failed = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                resultMessage = tr(
                    "\(titles.count) משימות נשלחו ל-\(trimmedEmail) 🎉 הן יופיעו ברשימת המשימות שלו, עם התראה.",
                    "\(titles.count) tasks sent to \(trimmedEmail) 🎉 They'll appear in their task list, with a notification."
                )
            }
        } catch {
            failed = true
            resultMessage = error.localizedDescription
        }
    }
}
