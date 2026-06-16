import Foundation
import SwiftUI

/// The two UI languages the app supports. Hebrew is the default; English is a
/// full mirror selectable from Settings. The choice is independent of the iOS
/// system language — it's a manual in-app toggle.
///
/// This lives in `Shared/` (and is a member of every target) so the global
/// `tr(_:_:)` helper is in scope wherever localized strings appear — the main
/// app, the widget, the watch app, and the share extension all compile it.
enum AppLang: String, CaseIterable, Identifiable {
    case he, en
    var id: String { rawValue }

    /// What to show on the toggle.
    var display: String { self == .he ? "עברית" : "English" }

    var locale: Locale { Locale(identifier: self == .he ? "he_IL" : "en_US") }

    var layoutDirection: LayoutDirection { self == .he ? .rightToLeft : .leftToRight }
}

/// Plain global mirror of the current language so the free `tr(_:_:)` helper
/// can be called from anywhere — including `nonisolated` code and the on-device
/// notification builders — without threading an EnvironmentObject through every
/// call site. Kept in sync by `LanguageManager` in the main app; other targets
/// (extension/widget/watch) read it once from the App Group at first use.
///
/// Reads the App Group defaults directly (not via `SharedStore`) so this file
/// has no cross-target dependency — the share extension doesn't compile
/// `SharedStore.swift`.
enum AppLangBox {
    nonisolated(unsafe) static var current: AppLang = {
        let raw = UserDefaults(suiteName: "group.com.rani.Limor-Ai-App")?
            .string(forKey: "limor.appLang") ?? "he"
        return AppLang(rawValue: raw) ?? .he
    }()
}

/// Pick the string for the current UI language. The English text lives right
/// next to the Hebrew at each call site, so there's no separate key table to
/// keep in sync. Example: `Text(tr("שלח", "Send"))`.
func tr(_ he: String, _ en: String) -> String {
    AppLangBox.current == .en ? en : he
}
