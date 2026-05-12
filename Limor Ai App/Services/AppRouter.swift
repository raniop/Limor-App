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

    enum Tab: Hashable {
        case now, reminders, chat, settings, custom
    }

    /// Convenience: jump to chat and queue a message for auto-send.
    func sendToLimor(_ text: String) {
        pendingChatMessage = text
        selectedTab = .chat
    }
}
