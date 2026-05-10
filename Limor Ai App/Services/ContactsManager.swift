import Contacts
import Foundation

@MainActor
final class ContactsManager: ObservableObject {
    static let shared = ContactsManager()

    private let store = CNContactStore()
    @Published private(set) var hasAccess = false

    func requestAccess() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        hasAccess = granted
        return granted
    }

    func fetchAllContacts() async -> [ContactDTO] {
        guard hasAccess else { return [] }
        let store = self.store

        return await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey,
                CNContactFamilyNameKey,
                CNContactPhoneNumbersKey,
                CNContactEmailAddressesKey,
                CNContactOrganizationNameKey,
            ] as [CNKeyDescriptor]

            let request = CNContactFetchRequest(keysToFetch: keys)
            var contacts: [ContactDTO] = []

            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    let phones = contact.phoneNumbers.map { $0.value.stringValue }
                    let emails = contact.emailAddresses.map { String($0.value) }
                    if phones.isEmpty && emails.isEmpty { return }

                    let parts = [contact.givenName, contact.familyName]
                        .filter { !$0.isEmpty }
                    let displayName = parts.isEmpty
                        ? contact.organizationName
                        : parts.joined(separator: " ")
                    guard !displayName.isEmpty else { return }

                    let aliases = generateAliases(
                        givenName: contact.givenName,
                        familyName: contact.familyName,
                        displayName: displayName
                    )

                    contacts.append(ContactDTO(
                        identifier: contact.identifier,
                        given_name: contact.givenName.isEmpty ? nil : contact.givenName,
                        family_name: contact.familyName.isEmpty ? nil : contact.familyName,
                        display_name: displayName,
                        phones: phones,
                        emails: emails,
                        organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                        aliases: aliases.isEmpty ? nil : aliases
                    ))
                }
            } catch {
                return []
            }
            return contacts
        }.value
    }
}

// MARK: - Alias generation (Hebrew ↔ Latin)

/// Returns alternate forms of the given name useful for cross-language search:
///   • given name alone
///   • Hebrew ↔ Latin transliteration of each part and the full name
///   • lowercased variants
///
/// The transliteration uses Apple's `CFStringTransform`. It's imperfect (Hebrew
/// has no vowels in standard text) but covers many common name patterns —
/// enough that "עמית גולן" matches "Amit Golan" and vice-versa.
private func generateAliases(
    givenName: String,
    familyName: String,
    displayName: String
) -> [String] {
    var set = Set<String>()

    func add(_ s: String?) {
        guard let s, !s.isEmpty else { return }
        set.insert(s)
        set.insert(s.lowercased())
    }

    if !givenName.isEmpty { add(givenName) }
    if !familyName.isEmpty { add(familyName) }

    // Transliterate the full display name in both directions.
    add(transliterate(displayName, to: .latin))
    add(transliterate(displayName, to: .hebrew))

    // Per-part transliterations (handles names mixed with non-letters).
    for part in [givenName, familyName] where !part.isEmpty {
        add(transliterate(part, to: .latin))
        add(transliterate(part, to: .hebrew))
    }

    // Drop the canonical display name to avoid duplication.
    set.remove(displayName)
    set.remove(displayName.lowercased())
    return Array(set)
}

private enum TransliterationTarget {
    case latin, hebrew
}

private func transliterate(_ s: String, to target: TransliterationTarget) -> String? {
    guard !s.isEmpty else { return nil }
    let mutable = NSMutableString(string: s)
    let transform: CFString
    switch target {
    case .latin:  transform = "Hebrew-Latin" as CFString
    case .hebrew: transform = "Latin-Hebrew" as CFString
    }
    guard CFStringTransform(mutable, nil, transform, false) else { return nil }
    let result = String(mutable)
    // Strip combining marks for cleaner matching.
    let stripped = result.applyingTransform(.stripCombiningMarks, reverse: false) ?? result
    return stripped == s ? nil : stripped
}
