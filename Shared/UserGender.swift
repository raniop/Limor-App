import Foundation

/// User's grammatical gender, captured during the intro chat and surfaced
/// across both the main app and the Share Extension so Hebrew strings can
/// match. We keep this in App Group `UserDefaults` so the Share Extension
/// (which runs in its own process and doesn't share memory with the host
/// app) can read it without round-tripping to the backend.
///
/// Storage key + group ID redeclared inline so this file compiles inside
/// the extension target without dragging `SharedStore.swift` along.
public enum UserGender: String, Sendable, Codable {
    case male, female, other

    private static let appGroupId = "group.com.rani.Limor-Ai-App"
    private static let storageKey = "limor.userGender"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupId) ?? .standard
    }

    /// The user's current gender as known on this device. Defaults to `.male`
    /// when nothing has been recorded — same default the intro view uses
    /// before the user makes a selection, so existing code that hard-coded
    /// masculine phrasing keeps working until the backfill lands.
    public static var current: UserGender {
        guard let raw = defaults.string(forKey: storageKey),
              let g = UserGender(rawValue: raw)
        else { return .male }
        return g
    }

    /// Set from the intro view (right when the user taps a button) and from
    /// the auth-manager backfill (when we load profile facts for a user who
    /// already completed intro on a previous install).
    public static func store(_ gender: UserGender) {
        defaults.set(gender.rawValue, forKey: storageKey)
    }

    /// Map the Hebrew label the backend stores (`"זכר"` / `"נקבה"` / `"אחר"`)
    /// back to the enum. Used by the profile-facts backfill — the intro
    /// submits the Hebrew form, so that's what comes back from the server.
    public static func fromHebrewLabel(_ label: String) -> UserGender? {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "זכר":  return .male
        case "נקבה": return .female
        case "אחר":  return .other
        default:     return nil
        }
    }

    /// Convenience: pick between a male and female form of a Hebrew string.
    /// `.other` falls through to the male form because that's the existing
    /// app convention; if/when we want a slash form there we can flip this.
    public func pick(male: String, female: String) -> String {
        switch self {
        case .male, .other: return male
        case .female:       return female
        }
    }

    /// Shorthand for the common case: read the stored gender and pick the
    /// right Hebrew form in one call.
    public static func pick(male: String, female: String) -> String {
        current.pick(male: male, female: female)
    }
}
