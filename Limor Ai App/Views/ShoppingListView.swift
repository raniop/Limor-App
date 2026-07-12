import SwiftUI

// MARK: - Store
//
// Single-device shopping list, persisted in App Group UserDefaults via
// SharedStore. Observable so views update reactively as items are added /
// toggled / removed. Backend syncing isn't wired up — when we want
// cross-device sync we'll add an APIClient method and swap `persist()` for
// a remote upsert.
@MainActor
final class ShoppingListStore: ObservableObject {
    static let shared = ShoppingListStore()

    @Published private(set) var activeGroup: ShoppingGroup
    @Published private(set) var archive: [ShoppingGroup]

    /// Backwards-compatible accessor — the chat detector and other call
    /// sites that just want "what's in the cart right now" read this.
    var items: [ShoppingItem] { activeGroup.items }

    private var poller: Timer?

    private init() {
        // iCloud is the source of truth for cross-device sync. Backend
        // PUT still happens so Limor's AI tools can read the list, but
        // we never READ FROM the backend — that overwrite path was
        // wiping items the user added on the other device.
        SharedStore.mirrorShoppingFromICloud()
        self.activeGroup = SharedStore.shoppingActiveGroup
        self.archive = SharedStore.shoppingArchive

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let keys = (note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]) ?? []
            print("[icloud] external change keys=\(keys)")
            self.applyICloud()
        }

        // iCloud KVS doesn't always fire the external-change notification
        // promptly while the app is in the foreground — simulator → real
        // device pairs are particularly flaky. Poll every 15s while the
        // store is alive (it's a singleton — never deallocs), calling
        // synchronize() to nudge iCloud and re-read if anything changed.
        // Cheap: the SDK skips the network when there's nothing new.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollICloudIfChanged() }
        }
    }

    /// Pull-down refresh — runs iCloud mirror + re-applies. Called from
    /// LimorAiApp.scenePhase=.active so iCloud propagation gets one more
    /// chance the moment the user comes back to the app.
    func refreshFromICloud() {
        applyICloud()
    }

    /// Re-read iCloud and update @Published state if it differs from
    /// what we already have. Avoids needless UI churn when nothing
    /// changed.
    private func applyICloud() {
        SharedStore.mirrorShoppingFromICloud()
        let newActive = SharedStore.shoppingActiveGroup
        let newArchive = SharedStore.shoppingArchive
        if newActive != activeGroup || newArchive != archive {
            activeGroup = newActive
            archive = newArchive
            print("[shopping] applied iCloud change — active=\(activeGroup.items.count) archive=\(archive.count)")
        }
    }

    private func pollICloudIfChanged() {
        NSUbiquitousKeyValueStore.default.synchronize()
        applyICloud()
    }

    /// Old backend-fetch entry point — kept so the silent-push handler
    /// (when APNs is fixed) and any external callers continue to compile.
    /// Now a thin wrapper around iCloud refresh so we never overwrite
    /// local state with a stale backend snapshot.
    func refreshFromBackend() async {
        applyICloud()
    }

    /// Returns true if the item was added (false on duplicate of an open item).
    /// Comparison is case-insensitive AND diacritic-insensitive so "חלב",
    /// "חָלָב" (with niqqud) and "Milk" / "milk" all collapse to the same
    /// entry. Completed items DON'T block — if you bought milk and now need
    /// to buy it again, the second add is a fresh entry on purpose.
    @discardableResult
    func add(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let normalized = Self.normalize(name)
        if activeGroup.items.contains(where: { !$0.completed && Self.normalize($0.name) == normalized }) {
            return false
        }
        activeGroup.items.insert(ShoppingItem(name: name), at: 0)
        persist()
        return true
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "he_IL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Find an open (non-completed) item by name and mark it complete.
    /// Case- + diacritic-insensitive match, same normalization used by
    /// `add()` so "Milk" / "חלב" / "חָלָב" all match a single canonical
    /// entry. Returns true if an item was found and toggled.
    /// Used by the FCM silent-push handler for Limor's
    /// `complete_shopping_item` tool — backend can't tick items off
    /// directly, so it asks the device to do it by name.
    @discardableResult
    func completeByName(_ rawName: String) -> Bool {
        let normalized = Self.normalize(rawName)
        guard let match = activeGroup.items.first(where: {
            !$0.completed && Self.normalize($0.name) == normalized
        }) else { return false }
        toggle(match.id)
        return true
    }

    func toggle(_ id: UUID) {
        guard let idx = activeGroup.items.firstIndex(where: { $0.id == id }) else { return }
        activeGroup.items[idx].completed.toggle()
        // Combined mutation: if this toggle completed the last item, archive
        // BEFORE we persist so we ship a single consolidated state to
        // backend / iCloud. Two back-to-back persists raced over the
        // network and the older "all checked, not archived yet" snapshot
        // could land last, leaving other devices stuck in the middle
        // state.
        if activeGroup.isFullyCompleted {
            var done = activeGroup
            done.archived_at = ISO8601DateFormatter.limor.string(from: Date())
            archive.insert(done, at: 0)
            activeGroup = ShoppingGroup()
        }
        persist()
    }

    func remove(_ id: UUID) {
        activeGroup.items.removeAll { $0.id == id }
        persist()
    }

    func clearCompleted() {
        activeGroup.items.removeAll { $0.completed }
        persist()
    }

    /// Move an archived group's items back into the active list. Useful
    /// when the user wants to "redo" last week's shop — picks the
    /// archived group and re-adds its items as fresh (uncompleted)
    /// entries on the current list.
    func restoreFromArchive(_ groupId: UUID) {
        guard let idx = archive.firstIndex(where: { $0.id == groupId }) else { return }
        let group = archive[idx]
        for item in group.items.reversed() {
            // Skip duplicates of currently-open items.
            let normalized = Self.normalize(item.name)
            if activeGroup.items.contains(where: { !$0.completed && Self.normalize($0.name) == normalized }) {
                continue
            }
            activeGroup.items.insert(ShoppingItem(name: item.name), at: 0)
        }
        persist()
    }

    func deleteArchived(_ groupId: UUID) {
        archive.removeAll { $0.id == groupId }
        persist()
    }

    private func persist() {
        SharedStore.shoppingActiveGroup = activeGroup
        SharedStore.shoppingArchive = archive
        // Fire-and-forget push to the Limor backend so other devices /
        // Limor's AI tools see the change. Failure here is silent — the
        // local cache + iCloud keep working, and the next foreground
        // refresh will reconcile.
        let snapshot = ShoppingStateDTO(active: activeGroup, archive: archive)
        Task { try? await APIClient.shared.putShoppingState(snapshot) }
        // Mirror the change over WCSession to the watch — App Group +
        // iCloud KVS don't bridge between simulator processes, and on
        // real devices this is faster than waiting for the KVS push.
        WatchSyncManager.shared.pushSnapshot()
    }
}

// MARK: - Full screen list view

struct ShoppingListView: View {
    @StateObject private var store = ShoppingListStore.shared
    /// The shared (couple) list — backend-owned. When the user is a member,
    /// it's pinned at the top of this screen so it's never "hidden" behind
    /// the toolbar button again.
    @StateObject private var sharedStore = SharedShoppingStore.shared
    @State private var newItemDraft: String = ""
    @FocusState private var inputFocused: Bool
    @State private var showingArchive = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ZStack {
            LiquidBackdrop()
            VStack(spacing: 0) {
                addBar
                if store.items.isEmpty && !sharedStore.isActive {
                    emptyState
                } else {
                    list
                }
            }
        }
        .navigationTitle(tr("רשימת קניות", "Shopping List"))
        .navigationBarTitleDisplayMode(.large)
        .task {
            // Wake iCloud + force a re-read the moment the user opens
            // the shopping screen. Catches whatever propagated since
            // the last poll without waiting up to 5 seconds.
            NSUbiquitousKeyValueStore.default.synchronize()
            store.refreshFromICloud()
            // Refresh the shared list too — otherwise the pinned card
            // only appears after visiting the shared screen once.
            await sharedStore.load()
        }
        .toolbar {
            // Bare icons only — the system toolbar draws its own glass
            // capsule on iOS 26; a hand-drawn tinted capsule inside it
            // looked like a purple blob (see RemindersView).
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(destination: SharedShoppingView()) {
                    Image(systemName: "person.2.fill")
                        .fontWeight(.semibold)
                }
                .tint(.limorIndigo)
            }
            // Archive button on the leading side — only renders once the
            // user has at least one archived group to look back at.
            // Inline label with the count so we don't have to lay out a
            // floating badge inside a navigation-bar item (cramped).
            if !store.archive.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: ShoppingArchiveView()) {
                        HStack(spacing: 4) {
                            Image(systemName: "tray.full")
                                .fontWeight(.semibold)
                            Text("\(store.archive.count)")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                        }
                    }
                    .tint(.limorIndigo)
                }
            }
            if store.items.contains(where: { $0.completed }) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tr("נקה סומנו", "Clear checked")) {
                        withAnimation { store.clearCompleted() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorIndigo)
                }
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundStyle(.limorIndigo)
            TextField(tr("הוסף פריט (למשל: חלב)", "Add an item (e.g. Milk)"), text: $newItemDraft)
                .submitLabel(.done)
                .focused($inputFocused)
                .onSubmit(addDraft)
            if !newItemDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(tr("הוסף", "Add"), action: addDraft)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(LimorGradient.brand))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func addDraft() {
        let name = newItemDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        withAnimation { _ = store.add(name) }
        newItemDraft = ""
    }

    private var list: some View {
        ScrollView {
            if sharedStore.isActive {
                sharedCard
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .frame(maxWidth: hSizeClass == .regular ? 1100 : .infinity)
                    .frame(maxWidth: .infinity)
            }
            Group {
                if hSizeClass == .regular {
                    // iPad → flow items into 2–3 columns to use the width.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 460), spacing: 10)],
                              alignment: .leading, spacing: 10) {
                        ForEach(store.items) { item in
                            row(for: item)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(store.items) { item in
                            row(for: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 32)
            .frame(maxWidth: hSizeClass == .regular ? 1100 : .infinity)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func row(for item: ShoppingItem) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { store.toggle(item.id) }
            } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.completed ? Color.limorSuccess : Color.limorIndigo)
            }
            .buttonStyle(.plain)

            Text(item.name)
                .font(.body)
                .foregroundStyle(item.completed ? .limorMuted : .limorInk)
                .strikethrough(item.completed)

            Spacer()

            Button {
                withAnimation { store.remove(item.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.limorMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Pinned shared-list card — always the first thing on the screen when
    /// the user is in a shared list. Open items can be ticked right here;
    /// tapping the header opens the full shared screen (invite QR, delete,
    /// completed items).
    private var sharedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(destination: SharedShoppingView()) {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                    Text(tr("רשימה משותפת", "Shared list"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.limorInk)
                    Spacer()
                    Text("\(sharedStore.openItems.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.limorIndigo)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.limorIndigo.opacity(0.15)))
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.limorMuted)
                }
            }
            .buttonStyle(.plain)

            if sharedStore.openItems.isEmpty {
                Text(tr("אין פריטים פתוחים — הוסיפו במסך המשותף או בצ'אט.", "No open items — add some on the shared screen or in chat."))
                    .font(.caption)
                    .foregroundStyle(.limorMuted)
            } else {
                VStack(spacing: 6) {
                    ForEach(sharedStore.openItems) { item in
                        HStack(spacing: 12) {
                            Button {
                                Task { await sharedStore.toggle(item.id) }
                            } label: {
                                Image(systemName: "circle")
                                    .font(.title3)
                                    .foregroundStyle(.limorIndigo)
                            }
                            .buttonStyle(.plain)
                            Text(item.name)
                                .font(.body)
                                .foregroundStyle(.limorInk)
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.limorIndigo.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.limorIndigo.opacity(0.25), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cart")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.limorMuted)
            Text(tr("הרשימה ריקה", "Your list is empty"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.limorInk)
            Text(tr("הוסף פריט למעלה, או פשוט אמור לי מילה אחת בצ'אט (לדוגמה: \"חלב\") ואני אוסיף אותה.", "Add an item above, or just say a single word in chat (for example: \"Milk\") and I'll add it for you."))
                .font(.subheadline)
                .foregroundStyle(.limorMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if !store.archive.isEmpty {
                NavigationLink(destination: ShoppingArchiveView()) {
                    Label(tr("הרשימות הקודמות (\(store.archive.count))", "Previous lists (\(store.archive.count))"), systemImage: "tray.full")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.limorIndigo)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.limorIndigo.opacity(0.10)))
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Archive view

/// Browses completed shopping groups, newest first. Each group can be
/// expanded to show its items, restored as a fresh batch onto the
/// active list, or deleted entirely.
struct ShoppingArchiveView: View {
    @StateObject private var store = ShoppingListStore.shared
    @State private var expandedGroupId: UUID?

    var body: some View {
        ZStack {
            LiquidBackdrop()
            if store.archive.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.archive) { group in
                            groupCard(group)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle(tr("רשימות קודמות", "Previous Lists"))
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private func groupCard(_ group: ShoppingGroup) -> some View {
        let isExpanded = expandedGroupId == group.id
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedGroupId = isExpanded ? nil : group.id
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.limorSuccess)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.summaryTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.limorInk)
                            Text(tr("\(group.items.count) פריטים", "\(group.items.count) items"))
                                .font(.caption)
                                .foregroundStyle(.limorMuted)
                        }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.items) { item in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                    .font(.caption2)
                                    .foregroundStyle(.limorSuccess)
                                Text(item.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.limorMuted)
                                    .strikethrough()
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            withAnimation { store.restoreFromArchive(group.id) }
                        } label: {
                            Label(tr("שכפל לרשימה הפעילה", "Copy to active list"), systemImage: "doc.on.doc.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(LimorGradient.brand))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(role: .destructive) {
                            withAnimation { store.deleteArchived(group.id) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                                .foregroundStyle(.limorMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.limorMuted)
            Text(tr("אין רשימות קודמות עדיין", "No previous lists yet"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.limorInk)
            Text(tr("ברגע שכל הפריטים ברשימה הפעילה מסומנים, הרשימה עוברת אוטומטית לכאן ונפתחת רשימה חדשה.", "Once every item on the active list is checked off, the list moves here automatically and a fresh one opens."))
                .font(.subheadline)
                .foregroundStyle(.limorMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Home feed card

struct ShoppingListCard: View {
    @StateObject private var store = ShoppingListStore.shared

    private let displayLimit = 4

    var body: some View {
        NavigationLink(destination: ShoppingListView()) {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionLabel(icon: "cart.fill", title: tr("רשימת קניות", "Shopping List"))
                        Spacer()
                        if openCount > 0 {
                            Text("\(openCount)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.limorIndigo))
                        }
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.limorMuted)
                    }

                    if store.items.isEmpty {
                        Text(tr("ריק בינתיים — אמור לי מילה אחת בצ'אט (\"חלב\") ואוסיף אותה", "Empty for now — say a single word in chat (\"Milk\") and I'll add it"))
                            .font(.subheadline)
                            .foregroundStyle(.limorMuted)
                            .multilineTextAlignment(.leading)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(visibleItems.prefix(displayLimit))) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                                        .font(.subheadline)
                                        .foregroundStyle(item.completed ? Color.limorSuccess : Color.limorIndigo)
                                    Text(item.name)
                                        .font(.subheadline.weight(item.completed ? .regular : .semibold))
                                        .foregroundStyle(item.completed ? .limorMuted : .limorInk)
                                        .strikethrough(item.completed)
                                    Spacer()
                                }
                            }
                            if store.items.count > displayLimit {
                                Text(tr("ועוד \(store.items.count - displayLimit)…", "\(store.items.count - displayLimit) more…"))
                                    .font(.caption)
                                    .foregroundStyle(.limorMuted)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var openCount: Int {
        store.items.filter { !$0.completed }.count
    }

    private var visibleItems: [ShoppingItem] {
        // Show open items first, then recently completed.
        store.items.sorted { lhs, rhs in
            if lhs.completed != rhs.completed { return !lhs.completed }
            return lhs.added_at > rhs.added_at
        }
    }
}
