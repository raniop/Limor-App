import ContactsUI
import SwiftUI

/// SwiftUI wrapper around `CNContactPickerViewController`. iOS's native
/// picker handles its own contacts-access prompt — no `NSContactsUsage…`
/// gymnastics from our side. Returns the picked contact's identifier +
/// display name + primary phone (or nil) via the callback.
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
        return vc
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPicked: (PickedContact) -> Void
        init(onPicked: @escaping (PickedContact) -> Void) { self.onPicked = onPicked }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let phone = contact.phoneNumbers.first?.value.stringValue
            onPicked(PickedContact(
                identifier: contact.identifier,
                displayName: name.isEmpty ? "(ללא שם)" : name,
                primaryPhone: phone
            ))
        }
    }
}
