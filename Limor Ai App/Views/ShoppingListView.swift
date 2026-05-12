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
    @discardableResult
    func add(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        // Reject duplicates of an open (not-yet-completed) entry —
        // re-adding "חלב" twice in a row makes no sense.
        if items.contains(where: { !$0.completed && $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            return false
        }
        items.insert(ShoppingItem(name: name), at: 0)
        persist()
        return true
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

// MARK: - Single-word shopping detection
//
// Heuristic: if the user's chat input is a single short word in Hebrew or
// English (and isn't a common conversational reply like "כן"/"thanks"),
// treat it as a shopping list addition instead of a chat message. The user
// can always force a chat by typing more than one word or adding "?".
enum ShoppingDetector {

    /// Stopwords we explicitly DON'T want to treat as groceries — these are
    /// common short chat replies. Lowercased; comparison is case-insensitive.
    private static let stopwords: Set<String> = [
        // Hebrew chat replies
        "כן", "לא", "אוקיי", "אוקי", "תודה", "תודות", "סליחה", "היי", "שלום", "ביי",
        "וואלה", "וואו", "אוף", "אהה", "אה", "מה", "מי", "איך", "מתי", "איפה", "למה",
        "טוב", "רע", "בסדר", "מעולה", "נהדר", "סבבה",
        // English chat replies
        "yes", "no", "ok", "okay", "thanks", "thank", "hi", "hello", "hey",
        "bye", "wow", "what", "who", "how", "when", "where", "why",
        "sure", "yep", "yeah", "nope", "fine", "good", "bad", "great",
    ]

    static func looksLikeShoppingItem(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject if contains spaces (must be exactly one word).
        if trimmed.contains(" ") { return false }
        // Reject if it has typical "chat" punctuation.
        if trimmed.contains("?") || trimmed.contains("!") || trimmed.contains(",") {
            return false
        }
        // Sanity bounds — 2..30 chars, letters only.
        guard trimmed.count >= 2, trimmed.count <= 30 else { return false }
        let isLetter: (Character) -> Bool = { c in
            c.isLetter || c == "'" || c == "-" || c == "\""
        }
        guard trimmed.allSatisfy(isLetter) else { return false }
        // Stopword check, case-insensitive.
        if stopwords.contains(trimmed.lowercased()) { return false }
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
