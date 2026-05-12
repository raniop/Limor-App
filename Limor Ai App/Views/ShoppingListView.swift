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

    @Published private(set) var items: [ShoppingItem]

    private init() {
        self.items = SharedStore.shoppingItems
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
        if items.contains(where: { !$0.completed && Self.normalize($0.name) == normalized }) {
            return false
        }
        items.insert(ShoppingItem(name: name), at: 0)
        persist()
        return true
    }

    /// Casefolded + diacritic-stripped form used for duplicate detection.
    /// `localizedLowercase` handles Turkish/German edge cases; folding to
    /// `String.CompareOptions.diacriticInsensitive` via `folding(options:locale:)`
    /// strips Hebrew niqqud + accent marks on Latin characters.
    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "he_IL"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func toggle(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].completed.toggle()
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clearCompleted() {
        items.removeAll { $0.completed }
        persist()
    }

    private func persist() {
        SharedStore.shoppingItems = items
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

        // Split on newlines, commas, semicolons, and Hebrew-style bullets
        // (•, *). The user might type "חלב, לחם, ביצים" inline, or each
        // item on its own line.
        let pieces = trimmed
            .components(separatedBy: CharacterSet.newlines.union(.init(charactersIn: ",;•*")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return [] }

        var items: [String] = []
        for piece in pieces {
            guard looksLikeItem(piece) else { return [] } // All-or-nothing
            items.append(piece)
        }
        return items
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
        if text.contains("?") { return true }
        let lower = text.lowercased()
        return chatMarkers.contains { lower.contains($0) }
    }

    /// Stopwords for SINGLE-word inputs only — multi-word items like
    /// "תירס שימורים" don't get checked against this list (each part can
    /// be anything; the whole-string allowance is what matters).
    private static let singleWordStopwords: Set<String> = [
        "כן", "לא", "אוקיי", "אוקי", "תודה", "תודות", "סליחה", "היי", "שלום", "ביי",
        "וואלה", "וואו", "אוף", "אהה", "אה", "מה", "מי", "טוב", "רע", "בסדר", "מעולה",
        "נהדר", "סבבה",
        "yes", "no", "ok", "okay", "thanks", "thank", "hi", "hello", "hey",
        "bye", "wow", "what", "who", "sure", "yep", "yeah", "nope",
        "fine", "good", "bad", "great",
    ]

    private static func looksLikeItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 40 else { return false }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty, words.count <= 4 else { return false }

        // Each character must be a letter, digit, space, or one of the
        // grocery-friendly punctuation marks ('-', "'", '%', '/', '.').
        let allowed: (Character) -> Bool = { c in
            c.isLetter || c.isNumber || c.isWhitespace
                || c == "-" || c == "'" || c == "\"" || c == "%" || c == "/" || c == "."
        }
        guard trimmed.allSatisfy(allowed) else { return false }

        if words.count == 1, singleWordStopwords.contains(trimmed.lowercased()) {
            return false
        }
        return true
    }
}

// MARK: - Full screen list view

struct ShoppingListView: View {
    @StateObject private var store = ShoppingListStore.shared
    @State private var newItemDraft: String = ""
    @FocusState private var inputFocused: Bool

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
        .toolbar {
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
