import Foundation

/// App-wide navigation hub. Lets a deep-link or in-app CTA jump to a specific
/// tab and (optionally) hand the destination view some payload — e.g. tapping
/// a recommendation's CTA should switch to the Chat tab and pre-send the
/// suggested message to Limor.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// Selected tab in MainTabs. Bound to TabView's selection.
    @Published var selectedTab: Tab = .now

    /// A message that should be auto-sent to Limor on next ChatView appear.
    /// ChatView reads, sends it, and clears the value.
    @Published var pendingChatMessage: String?

    /// An image attachment that should ride along on the next ChatView
    /// auto-send. Set by the Share-Extension handoff; ChatView pre-fills
    /// its attachment composer state from this, then clears it. Always
    /// paired with `pendingChatMessage` (which may be just a caption).
    @Published var pendingChatAttachment: PendingAttachment?

    struct PendingAttachment: Equatable {
        let data: Data
        let mime: String
        let filename: String
    }

    /// Bumped every time the user re-taps the Chat tab while already on
    /// it. ChatView observes this and scrolls to the latest message —
    /// overrides iOS's default "tap tab again → scroll to top", which
    /// goes the wrong way for a thread anchored at the bottom.
    @Published var chatScrollToBottomNonce: UUID = UUID()

    enum Tab: Hashable {
        case now, reminders, chat, settings, custom
    }

    /// Convenience: jump to chat and queue a message for auto-send.
    func sendToLimor(_ text: String) {
        pendingChatMessage = text
        selectedTab = .chat
    }

    /// Same as `sendToLimor(_:)` but also stages an image attachment that
    /// ChatView will paperclip onto the outgoing bubble. `text` may be empty
    /// (a caption isn't required for image shares).
    func sendToLimor(text: String, attachment: PendingAttachment) {
        pendingChatAttachment = attachment
        // Always set pendingChatMessage too — ChatView's send() needs *some*
        // signal to fire. Empty string is fine; send() guards on text or
        // attachment, so an image-only share still ships.
        pendingChatMessage = text
        selectedTab = .chat
    }

    /// Called by the TabView binding whenever the user taps a tab item.
    /// If they tapped the Chat tab while already on it, fire a
    /// scroll-to-bottom nonce so ChatView can jump to the newest bubble.
    func handleTabTap(_ tapped: Tab) {
        if tapped == .chat && selectedTab == .chat {
            chatScrollToBottomNonce = UUID()
        }
        selectedTab = tapped
    }
}
