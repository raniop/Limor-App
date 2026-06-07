import Foundation

/// Holds the user's shared shopping list (if any). Unlike the personal list
/// (iCloud-backed), the shared list lives on the backend so both members see
/// the same items. Every mutation optimistically updates `list` then PUTs the
/// new items; the backend fans out a silent "shopping_shared" push so the
/// other member's device refreshes within ~1s.
@MainActor
final class SharedShoppingStore: ObservableObject {
    static let shared = SharedShoppingStore()

    @Published private(set) var list: SharedShoppingList?
    @Published var errorMessage: String?

    var isActive: Bool { list != nil }
    var items: [ShoppingItem] { list?.items ?? [] }
    var openItems: [ShoppingItem] { items.filter { !$0.completed } }
    var doneItems: [ShoppingItem] { items.filter { $0.completed } }

    /// Refresh from the backend (cold launch, foreground, or shopping_shared push).
    func load() async {
        if let fetched = try? await APIClient.shared.getSharedList() {
            list = fetched
        }
    }

    func create() async {
        do { list = try await APIClient.shared.createSharedList() }
        catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func join(code: String) async -> Bool {
        do {
            if let joined = try await APIClient.shared.joinSharedList(code: code) {
                list = joined
                return true
            }
            errorMessage = "קוד לא תקין"
            return false
        } catch {
            // 404 → invalid code; surface a friendly message.
            errorMessage = "קוד לא תקין או שגיאה בחיבור"
            return false
        }
    }

    func leave() async {
        try? await APIClient.shared.leaveSharedList()
        list = nil
    }

    func add(_ rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var l = list else { return }
        guard !l.items.contains(where: { !$0.completed && $0.name.lowercased() == name.lowercased() }) else { return }
        l.items.append(ShoppingItem(name: name))
        list = l
        await push()
    }

    func toggle(_ id: UUID) async {
        guard var l = list, let i = l.items.firstIndex(where: { $0.id == id }) else { return }
        l.items[i].completed.toggle()
        list = l
        await push()
    }

    func remove(_ id: UUID) async {
        guard var l = list else { return }
        l.items.removeAll { $0.id == id }
        list = l
        await push()
    }

    func clearCompleted() async {
        guard var l = list else { return }
        l.items.removeAll { $0.completed }
        list = l
        await push()
    }

    private func push() async {
        guard let l = list else { return }
        if let updated = try? await APIClient.shared.putSharedListItems(l.items) {
            list = updated
        }
    }
}
