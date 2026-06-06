import Foundation

/// Queue of items handed off from the iOS Share Sheet (via `LimorShareExtension`)
/// to the main app. Backed by the App Group container so both processes see
/// the same state. Text goes through App Group `UserDefaults`; image blobs
/// live as files alongside it because `UserDefaults` is not a place for
/// arbitrary-size binary data.
///
/// Lifecycle: the extension calls `enqueue(...)`, then opens `limor://share`
/// which wakes the main app. The main app calls `drainAll()` once and
/// processes whatever it gets — text goes to the chat composer as a message,
/// the image rides along as the attachment.
public struct ShareInboxItem: Codable, Identifiable, Hashable {
    public let id: UUID
    public let createdAt: Date
    public let text: String?
    /// Filename (no directory) of the image stored inside the inbox dir.
    /// `nil` for text-only shares.
    public let imageFilename: String?
}

public enum ShareInbox {
    /// Must stay in sync with the App Group ID in both targets' entitlements.
    /// Redeclared here so this file can compile inside the Share Extension
    /// target without dragging in the rest of `SharedStore`.
    private static let appGroupId = "group.com.rani.Limor-Ai-App"
    private static let inboxKey = "limor.shareInbox.v1"
    private static let openChatFlagKey = "limor.shareInbox.shouldOpenChat"

    /// Set by the Share Extension when the user taps "פתח בצ׳אט", read +
    /// cleared by the host app on next foreground. Acts as a robust fallback
    /// for the `limor://share` URL trampoline, which can silently fail in
    /// iOS 18 when neither `extensionContext.open` nor the responder-chain
    /// `openURL:` walk manages to launch the host app. If the URL ever
    /// reaches the host, *it* also sets the same flag handling — both
    /// paths converge on "next time the app is in the foreground, jump to
    /// the chat tab".
    public static var shouldOpenChat: Bool {
        get { defaults.bool(forKey: openChatFlagKey) }
        set {
            if newValue {
                defaults.set(true, forKey: openChatFlagKey)
            } else {
                defaults.removeObject(forKey: openChatFlagKey)
            }
        }
    }

    /// Folder inside the App Group container that holds queued image blobs.
    /// Created lazily on first write.
    private static var inboxDirectory: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
        else { return nil }
        let dir = container.appendingPathComponent("share-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupId) ?? .standard
    }

    /// Append one item to the queue. Returns the persisted item (with its
    /// generated id + timestamp) so the caller can show a confirmation, or
    /// `nil` if the App Group container wasn't reachable.
    @discardableResult
    public static func enqueue(text: String?, imageData: Data?) -> ShareInboxItem? {
        let id = UUID()
        var imageFilename: String? = nil
        if let imageData, !imageData.isEmpty {
            guard let dir = inboxDirectory else { return nil }
            let name = "\(id.uuidString).jpg"
            do {
                try imageData.write(to: dir.appendingPathComponent(name), options: .atomic)
                imageFilename = name
            } catch {
                return nil
            }
        }
        let item = ShareInboxItem(
            id: id,
            createdAt: Date(),
            text: text?.isEmpty == true ? nil : text,
            imageFilename: imageFilename
        )
        var items = loadItems()
        items.append(item)
        saveItems(items)
        return item
    }

    /// Pull and remove every queued item, oldest first. The main app calls
    /// this when handling `limor://share`. Image data for each item must be
    /// read via `consumeImageData(for:)` *before* the item goes out of
    /// scope, otherwise the file is left behind until the next drain.
    public static func drainAll() -> [ShareInboxItem] {
        let items = loadItems().sorted { $0.createdAt < $1.createdAt }
        defaults.removeObject(forKey: inboxKey)
        return items
    }

    /// Read (and delete) the image blob for a drained item. Returns `nil` if
    /// the item is text-only, or if the file has already been removed.
    public static func consumeImageData(for item: ShareInboxItem) -> Data? {
        guard let name = item.imageFilename,
              let dir = inboxDirectory
        else { return nil }
        let url = dir.appendingPathComponent(name)
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }

    private static func loadItems() -> [ShareInboxItem] {
        guard let data = defaults.data(forKey: inboxKey) else { return [] }
        return (try? JSONDecoder().decode([ShareInboxItem].self, from: data)) ?? []
    }

    private static func saveItems(_ items: [ShareInboxItem]) {
        if items.isEmpty {
            defaults.removeObject(forKey: inboxKey)
            return
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: inboxKey)
    }
}
