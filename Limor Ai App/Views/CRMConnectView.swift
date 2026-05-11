import SwiftUI

/// "Connect to CRM" flow for users on the allowlist. Two steps —
///   1) phone + person ID → /api/crm/sendotp
///   2) OTP code         → /api/crm/verifyotp
/// On success we drop back into Settings with `connected: true`.
/// Disconnect lives in the same screen when already connected.
struct CRMConnectView: View {
    @Environment(\.dismiss) private var dismiss
    var initialStatus: CrmStatus
    var onChange: (CrmStatus) -> Void

    @State private var status: CrmStatus
    @State private var personId: String = ""
    @State private var phoneNumber: String = ""
    @State private var otpCode: String = ""
    @State private var step: Step = .enterPhone
    @State private var working = false
    @State private var errorMessage: String?

    enum Step { case enterPhone, enterOtp }

    init(status: CrmStatus, onChange: @escaping (CrmStatus) -> Void) {
        self.initialStatus = status
        self.onChange = onChange
        _status = State(initialValue: status)
    }

    var body: some View {
        ZStack {
            LiquidBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if status.connected {
                        connectedCard
                    } else if step == .enterPhone {
                        phoneForm
                    } else {
                        otpForm
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .navigationTitle("חיבור ל-CRM")
        .navigationBarTitleDisplayMode(.inline)
        .alert("שגיאה", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("אוקיי", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.limorIndigo)
                Text("חיבור מאובטח")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.limorInk)
            }
            Text("הקשר ל-BituhOfir עובר דרך השרת של לימור. הטוקנים לא נשמרים במכשיר.")
                .font(.caption)
                .foregroundStyle(.limorMuted)
        }
    }

    private var phoneForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(title: "תעודת זהות", text: $personId, keyboard: .numberPad, placeholder: "9 ספרות")
            field(title: "טלפון נייד", text: $phoneNumber, keyboard: .phonePad, placeholder: "05X-XXXXXXX")

            actionButton(title: "שלח קוד SMS") {
                Task { await sendOtp() }
            }
            .disabled(!canSendOtp)
        }
    }

    private var otpForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("שלחנו קוד ל-\(phoneNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.limorInk)
                Text("ת.ז.: \(personId)")
                    .font(.caption)
                    .foregroundStyle(.limorMuted)
            }

            field(
                title: "קוד OTP",
                text: $otpCode,
                keyboard: .numberPad,
                placeholder: "6 ספרות"
            )

            actionButton(title: "אמת ושמור חיבור") {
                Task { await verifyOtp() }
            }
            .disabled(otpCode.count < 4 || working)

            Button("חזור — שינוי מספר") {
                step = .enterPhone
                otpCode = ""
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.limorMuted)
        }
    }

    private var connectedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.limorMint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("מחובר ל-CRM")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.limorInk)
                    if let phone = status.phone_number, !phone.isEmpty {
                        Text("טלפון: \(phone)")
                            .font(.caption)
                            .foregroundStyle(.limorMuted)
                    }
                }
            }

            Text("ניתוק מסיר את הטוקן מהשרת. תוכל להתחבר מחדש בכל עת.")
                .font(.caption)
                .foregroundStyle(.limorMuted)

            Button(role: .destructive) {
                Task { await disconnect() }
            } label: {
                HStack {
                    if working {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "xmark.circle")
                    }
                    Text("נתק חיבור")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.limorDanger.opacity(0.12))
                )
                .foregroundStyle(.limorDanger)
            }
            .disabled(working)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.limorMuted.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func field(
        title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.limorMuted)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textContentType(keyboard == .phonePad ? .telephoneNumber : .none)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.regularMaterial)
                )
        }
    }

    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if working {
                    ProgressView().tint(.white).scaleEffect(0.8)
                }
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LimorGradient.brand)
            )
        }
        .disabled(working)
        .opacity(working ? 0.6 : 1)
    }

    // MARK: - Validation

    private var canSendOtp: Bool {
        !working
            && personId.count >= 7
            && phoneNumber.filter(\.isNumber).count >= 9
    }

    // MARK: - Networking

    private func sendOtp() async {
        working = true
        defer { working = false }
        do {
            try await APIClient.shared.crmSendOtp(personId: personId, phoneNumber: phoneNumber)
            step = .enterOtp
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func verifyOtp() async {
        working = true
        defer { working = false }
        do {
            try await APIClient.shared.crmVerifyOtp(
                personId: personId,
                otpCode: otpCode,
                phoneNumber: phoneNumber
            )
            let next = CrmStatus(
                allowed: true,
                connected: true,
                phone_number: phoneNumber,
                connected_at: ISO8601DateFormatter.limor.string(from: Date())
            )
            status = next
            onChange(next)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func disconnect() async {
        working = true
        defer { working = false }
        do {
            try await APIClient.shared.crmDisconnect()
            let next = CrmStatus(allowed: true, connected: false, phone_number: nil, connected_at: nil)
            status = next
            onChange(next)
            personId = ""
            phoneNumber = ""
            otpCode = ""
            step = .enterPhone
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
