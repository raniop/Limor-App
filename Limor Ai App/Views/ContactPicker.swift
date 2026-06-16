import ContactsUI
import SwiftUI

/// SwiftUI wrapper around `CNContactPickerViewController`. iOS's native
/// picker handles its own contacts-access prompt — no `NSContactsUsage…`
/// gymnastics from our side. Returns the picked contact's identifier +
/// display name + phone number via the callback.
///
/// Multi-phone handling: when a contact has more than one phone number we
/// route the user through the contact-detail screen so they actually pick
/// which line to use. Without the predicate gymnastics below, iOS auto-
/// returns the contact on tap and we silently default to the first phone —
/// which often isn't the mobile line and is the wrong one for "call".
struct ContactPicker: UIViewControllerRepresentable {
    var onPicked: (PickedContact) -> Void

    struct PickedContact {
        let identifier: String
        let displayName: String
        let primaryPhone: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.delegate = context.coordinator
        // Keys we need to render + persist the picked contact.
        vc.displayedPropertyKeys = [
            CNContactPhoneNumbersKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
        ]
        // Auto-pick the contact only when there's at most one phone number
        // (nothing to disambiguate). Anything else falls through to the
        // contact-detail screen where the user explicitly taps a number.
        vc.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count <= 1")
        // Inside the contact-detail screen, accept only phone-number taps.
        vc.predicateForSelectionOfProperty = NSPredicate(format: "key == 'phoneNumbers'")
        return vc
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPicked: (PickedContact) -> Void
        init(onPicked: @escaping (PickedContact) -> Void) { self.onPicked = onPicked }

        /// Fires for contacts that match `predicateForSelectionOfContact`
        /// (≤1 phone). No disambiguation needed — return the single phone
        /// if present, or nil.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let phone = contact.phoneNumbers.first?.value.stringValue
            onPicked(PickedContact(
                identifier: contact.identifier,
                displayName: displayName(for: contact),
                primaryPhone: phone
            ))
        }

        /// Fires when the user taps a specific phone row inside the
        /// contact-detail screen (multi-phone contacts). `property.value`
        /// is the `CNPhoneNumber` they picked.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            let phone = (contactProperty.value as? CNPhoneNumber)?.stringValue
            onPicked(PickedContact(
                identifier: contactProperty.contact.identifier,
                displayName: displayName(for: contactProperty.contact),
                primaryPhone: phone
            ))
        }

        private func displayName(for contact: CNContact) -> String {
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? tr("(ללא שם)", "(No name)") : name
        }
    }
}
