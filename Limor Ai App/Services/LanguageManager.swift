import SwiftUI

// `AppLang`, `AppLangBox`, and the global `tr(_:_:)` helper live in
// `Shared/Localization.swift` so they're in scope across all targets.

/// The single source of truth for the UI language. Drives a full re-render of
/// the view tree on change (the root keys itself by `lang`), and mirrors the
/// choice to the App Group + backend so widgets and server-generated content
/// (chat, news, briefings, notifications) follow the same language.
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var lang: AppLang {
        didSet {
            guard lang != oldValue else { return }
            SharedStore.appLang = lang.rawValue
            AppLangBox.current = lang
            Task { try? await APIClient.shared.setLanguage(lang.rawValue) }
        }
    }

    private init() {
        let stored = AppLang(rawValue: SharedStore.appLang) ?? .he
        lang = stored
        AppLangBox.current = stored
    }
}
