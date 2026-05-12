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

// MARK: - Shopping-list detection
//
// Heuristic for the chat composer: pull out grocery items from inputs that
// look like a shopping list, otherwise let the message go to the chat
// backend. Supports:
//   - Single word ("חלב")
//   - Multi-line list (one item per line, separated by \n)
//   - Comma-separated list ("חלב, לחם, ביצים")
//   - Items with up to ~4 words ("תירס שימורים", "milk 2% lite")
// Rejects anything that smells like a question / imperative ("תזכיר…",
// "what's…", trailing "?").
enum ShoppingDetector {

    /// Returns the grocery items extracted from `text`. Empty array means
    /// "this doesn't look like shopping — send to chat".
    static func extractShoppingItems(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Quick reject for anything that looks like a chat sentence — a
        // question / command, a long-form prose, etc.
        if hasChatMarkers(trimmed) { return [] }

        // iOS dictation with `addsPunctuation` likes to drop a sentence-
        // final period or exclamation onto the last item ("ביצים חלב
        // גבינה."), which kills the per-word allowed-character check.
        // Strip those off every piece + every space-split atom.
        let trailingPunct = CharacterSet(charactersIn: ".!?;:")

        // Split on newlines, commas, semicolons, and Hebrew-style bullets
        // (•, *). The user might type "חלב, לחם, ביצים" inline, or each
        // item on its own line.
        let delimiterSet = CharacterSet.newlines.union(.init(charactersIn: ",;•*"))
        let hasDelimiters = trimmed.unicodeScalars.contains { delimiterSet.contains($0) }
        let pieces = trimmed
            .components(separatedBy: delimiterSet)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(trailingPunct)) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return [] }

        // Voice-dictation case: one long piece with no delimiters and 3+
        // words. Hebrew speech-to-text rarely inserts commas between
        // dictated grocery items, so "ביצים חלב גבינה" arrives as a
        // single space-separated string. Without this fallback the
        // detector either rejects the whole thing (>4 words) or treats
        // it as one weird 5-word item — neither of which adds anything
        // useful to the list. Trade-off: compound items like "שוקולד
        // השחר" get split into two, which the user can manually merge.
        if !hasDelimiters && pieces.count == 1 {
            let words = pieces[0]
                .split(whereSeparator: { $0.isWhitespace })
                .map { String($0).trimmingCharacters(in: trailingPunct) }
                .filter { !$0.isEmpty }
            if words.count >= 3 {
                var atoms: [String] = []
                for word in words {
                    guard wordLooksLikeGroceryAtom(word) else { return [] }
                    atoms.append(word)
                }
                return atoms
            }
        }

        var items: [String] = []
        for piece in pieces {
            guard looksLikeItem(piece) else { return [] } // All-or-nothing
            items.append(piece)
        }
        return items
    }

    /// Stricter per-word check used when we're treating each space-
    /// separated word as its own grocery (voice-dictation fallback).
    /// Single chat words ("כן", "טוב", "what") must NEVER survive this
    /// path — otherwise a stray "כן" mid-conversation would land on the
    /// shopping list.
    private static func wordLooksLikeGroceryAtom(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 20 else { return false }
        guard trimmed.allSatisfy(Self.isGroceryChar) else { return false }
        if stopwords.contains(trimmed.lowercased()) { return false }
        return true
    }

    /// Whitelist of characters that can appear inside a grocery item
    /// name. Covers Hebrew + English letters, digits, whitespace, and
    /// the handful of punctuation marks that legitimately turn up in
    /// product names ("2%", "1/2 kg", "tirelle's", "ביה״ס", "קוטג׳").
    /// Without the Hebrew Geresh + Gershayim entries the detector
    /// silently rejected the whole input on multi-line lists that
    /// included "קוטג׳", and the Limor LLM then "added" the items via
    /// chat but the changes never propagated back to iCloud.
    private static func isGroceryChar(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber || c.isWhitespace { return true }
        switch c {
        case "-", "'", "\"", "%", "/", ".": return true
        case "\u{05F3}", "\u{05F4}":         return true // ׳ Geresh, ״ Gershayim
        case "\u{2019}", "\u{2018}":         return true // curly ’ ‘
        case "\u{201C}", "\u{201D}":         return true // curly “ ”
        default:                              return false
        }
    }

    /// Words that strongly imply the user is talking TO Limor rather than
    /// dictating a shopping list. Substring match against the lowercased
    /// input so "תזכיר לי" / "remind me" / "what's…" all bail out.
    private static let chatMarkers: [String] = [
        "תזכיר", "תזכרי", "תכניסי", "תוסיפי", "תוכל", "תוכלי", "האם",
        "מתי", "איך", "איפה", "למה", "כמה",
        "remind", "what", "when", "where", "why", "how", "can you",
    ]

    private static func hasChatMarkers(_ text: String) -> Bool {
        // iOS dictation occasionally appends a "?" to a perfectly
        // good grocery utterance ("ביצים?", "חלב!"). Treating any
        // input that contains "?" as a chat reply killed the
        // intercept for those dictations and forced the message
        // through the chat LLM — which would then claim to add the
        // items, while `ShoppingListStore` stayed empty. Strip
        // trailing punctuation before scanning; the marker word
        // list below still catches real questions ("מה ברשימה?",
        // "תוסיפי לי חלב?") because they contain `מה` / `תוסיפי`.
        let stripped = text
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:"))
            .lowercased()
        return chatMarkers.contains { stripped.contains($0) }
    }

    /// Conversational words that should NEVER appear inside a shopping
    /// item. If we see any of these anywhere in the input we treat it as
    /// a chat reply, not a grocery line — covers cases like "כן היום"
    /// (answering Limor's "when?") that would otherwise slip past the
    /// single-word stopword check.
    private static let stopwords: Set<String> = [
        // Hebrew chat replies / function words
        "כן", "לא", "אוקיי", "אוקי", "תודה", "תודות", "סליחה", "היי", "שלום", "ביי",
        "וואלה", "וואו", "אוף", "אהה", "אה", "מה", "מי", "טוב", "רע", "בסדר", "מעולה",
        "נהדר", "סבבה",
        "היום", "מחר", "אתמול", "עכשיו", "אחר", "כך", "בבוקר", "בערב", "בלילה",
        // English chat replies / function words
        "yes", "no", "ok", "okay", "thanks", "thank", "hi", "hello", "hey",
        "bye", "wow", "what", "who", "sure", "yep", "yeah", "nope",
        "fine", "good", "bad", "great",
        "today", "tomorrow", "yesterday", "now", "later",
    ]

    private static func looksLikeItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40 else { return false }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }

        // Each character must be a letter, digit, space, or one of the
        // grocery-friendly punctuation marks ('-', "'", '%', '/', '.').
        // Also accept the Hebrew Geresh (׳, U+05F3) and Gershayim (״,
        // U+05F4) — they're standard punctuation inside Hebrew nouns
        // like "קוטג׳", "פרופ׳", "ביה״ס", and Unicode classifies them
        // as `Po` (Other_Punctuation), not `Letter`, so the
        // `isLetter` check rejects them otherwise.
        guard trimmed.allSatisfy(Self.isGroceryChar) else { return false }

        // ANY stopword anywhere disqualifies — multi-word inputs like
        // "כן היום" / "yes today" / "wait מחר" aren't shopping lists.
        for word in words {
            if stopwords.contains(word.lowercased()) { return false }
        }
        return true
    }
}

// MARK: - Full screen list view

struct ShoppingListView: View {
    @StateObject private var store = ShoppingListStore.shared
    @State private var newItemDraft: String = ""
    @FocusState private var inputFocused: Bool
    @State private var showingArchive = false

    var body: some View {
        ZStack {
            LiquidBackdrop()
            VStack(spacing: 0) {
                addBar
                if store.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
        .navigationTitle("רשימת קניות")
        .navigationBarTitleDisplayMode(.large)
        .task {
            // Wake iCloud + force a re-read the moment the user opens
            // the shopping screen. Catches whatever propagated since
            // the last poll without waiting up to 5 seconds.
            NSUbiquitousKeyValueStore.default.synchronize()
            store.refreshFromICloud()
        }
        .toolbar {
            // Archive button on the leading side — only renders once the
            // user has at least one archived group to look back at.
            // Inline label with the count so we don't have to lay out a
            // floating badge inside a navigation-bar item (cramped).
            if !store.archive.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(destination: ShoppingArchiveView()) {
                        HStack(spacing: 4) {
                            Image(systemName: "tray.full")
                                .font(.subheadline.weight(.semibold))
                            Text("\(store.archive.count)")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.limorIndigo)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.limorIndigo.opacity(0.12)))
                    }
                }
            }
            if store.items.contains(where: { $0.completed }) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("נקה סומנו") {
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
            TextField("הוסף פריט (למשל: חלב)", text: $newItemDraft)
                .submitLabel(.done)
                .focused($inputFocused)
                .onSubmit(addDraft)
            if !newItemDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("הוסף", action: addDraft)
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
            VStack(spacing: 8) {
                ForEach(store.items) { item in
                    row(for: item)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 32)
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

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cart")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.limorMuted)
            Text("הרשימה ריקה")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.limorInk)
            Text("הוסף פריט למעלה, או פשוט אמור לי מילה אחת בצ'אט (לדוגמה: \"חלב\") ואני אוסיף אותה.")
                .font(.subheadline)
                .foregroundStyle(.limorMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if !store.archive.isEmpty {
                NavigationLink(destination: ShoppingArchiveView()) {
                    Label("הרשימות הקודמות (\(store.archive.count))", systemImage: "tray.full")
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
        .navigationTitle("רשימות קודמות")
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
                            Text("\(group.items.count) פריטים")
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
                            Label("שכפל לרשימה הפעילה", systemImage: "doc.on.doc.fill")
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
            Text("אין רשימות קודמות עדיין")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.limorInk)
            Text("ברגע שכל הפריטים ברשימה הפעילה מסומנים, הרשימה עוברת אוטומטית לכאן ונפתחת רשימה חדשה.")
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
                        SectionLabel(icon: "cart.fill", title: "רשימת קניות")
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
                        Text("ריק בינתיים — אמור לי מילה אחת בצ'אט (\"חלב\") ואוסיף אותה")
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
                                Text("ועוד \(store.items.count - displayLimit)…")
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
