import SwiftUI

// MARK: - Urgency display helpers

extension EmailUrgency {
    var label: String {
        switch self {
        case .critical: return "קריטי"
        case .high:     return "גבוה"
        case .medium:   return "השבוע"
        case .low:      return "לא דחוף"
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
                        SectionLabel(icon: "tray.full.fill", title: "מוקד המייל", tint: .limorViolet)
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
                        if nothingToShow {
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
                        emptyRow
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
                Label("\(followUps) פולואפים", systemImage: "arrowshape.turn.up.left.fill")
            }
            if risks > 0 {
                Label("\(risks) סיכונים", systemImage: "exclamationmark.triangle.fill")
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
            Text("הכול תחת שליטה — אין מיילים שדורשים טיפול").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.limorViolet).scaleEffect(0.7)
            Text("סורק את המייל…").font(.caption).foregroundStyle(.secondary)
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

// MARK: - Full report screen

struct EmailActionsView: View {
    @State private var report: EmailActionReport?
    @State private var loaded = false
    @State private var refreshing = false
    @State private var addedReminderItemIds: Set<String> = []
    @State private var errorMessage: String?
    @State private var dismissed: Set<String> = SharedStore.dismissedEmailActionKeys

    // Items the user marked "handled" are filtered out everywhere.
    private var visibleTop: [EmailActionItem] {
        (report?.top_items ?? []).filter { !dismissed.contains($0.dismissKey) }
    }
    private var visibleAdditional: [EmailActionItem] {
        (report?.additional_items ?? []).filter { !dismissed.contains($0.dismissKey) }
    }
    private var visibleFollowUps: [EmailFollowUp] {
        (report?.follow_ups ?? []).filter { !dismissed.contains($0.dismissKey) }
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
        .navigationTitle("מוקד המייל")
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
        .alert("שגיאה", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("אוקיי", role: .cancel) {}
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
                        if !visibleTop.isEmpty {
                            section(title: "החשובים ביותר", icon: "star.fill", tint: .limorViolet) {
                                ForEach(visibleTop) { item in actionCard(item) }
                            }
                        }
                        if !visibleAdditional.isEmpty {
                            section(title: "פעולות נוספות", icon: "list.bullet", tint: .limorIndigo) {
                                ForEach(visibleAdditional) { item in actionCard(item) }
                            }
                        }
                        if !visibleFollowUps.isEmpty {
                            section(title: "פולואפים שכדאי לשלוח", icon: "arrowshape.turn.up.left.fill", tint: .limorMint) {
                                ForEach(visibleFollowUps) { f in followUpCard(f) }
                            }
                        }
                        if !report.risks.isEmpty {
                            section(title: "סיכונים ודברים שאולי מתפספסים", icon: "exclamationmark.triangle.fill", tint: .limorWarning) {
                                ForEach(Array(report.risks.enumerated()), id: \.offset) { _, r in
                                    bulletRow(r, tint: .limorWarning)
                                }
                            }
                        }
                        if !report.todo.isEmpty {
                            section(title: "סדר העדיפויות שלך", icon: "checklist", tint: .limorIndigo) {
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
                Text("חשיבות \(item.importance)/10")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.limorMuted)
                if item.needs_review {
                    Text("לבדיקה")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.limorWarning)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.limorWarning.opacity(0.14)))
                }
                Spacer()
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
                Text("נושא: \(item.subject)")
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
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.bubble").font(.caption2).foregroundStyle(.limorViolet)
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.limorInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.limorViolet.opacity(0.08)))
            }

            HStack(spacing: 8) {
                reminderButton(item)
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
                Text(added ? "נוספה תזכורת" : "צור תזכורת")
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

    /// "Handled" — hide this item locally so it stops surfacing (survives the
    /// daily regeneration via the stable dismiss key).
    private func handledButton(_ key: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { dismiss(key) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                Text("טופל")
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
            Text("הכול תחת שליטה")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.limorInk)
            Text("אין כרגע מיילים שדורשים פעולה, החלטה או פולואפ.")
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

    private func refresh(force: Bool) async {
        guard !refreshing else { return }   // ignore a second tap mid-refresh
        refreshing = true
        defer { refreshing = false }
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
        return "עודכן \(f.string(from: date))"
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
