import LocalAuthentication

/// Wraps LocalAuthentication so callers can `await BiometricGate.authenticate(...)`
/// without dealing with the closure-based API. Falls back to device passcode
/// when biometrics aren't enrolled — the user still has to prove they own
/// the unlocked phone, just without the face/touch step.
enum BiometricGate {
    enum AuthError: LocalizedError {
        case canceled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .canceled:      return "האימות בוטל."
            case .failed(let m): return m
            }
        }
    }

    /// Prompts for Face ID / Touch ID / device passcode. Returns on success;
    /// throws on cancel or failure.
    static func authenticate(reason: String) async throws {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "השתמש בקוד מסך"
        var err: NSError?
        // .deviceOwnerAuthentication = biometrics if available, otherwise
        // passcode. Always something — never just refuses outright.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            throw AuthError.failed(err?.localizedDescription ?? "אימות לא זמין במכשיר.")
        }
        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let laErr as LAError {
            switch laErr.code {
            case .userCancel, .appCancel, .systemCancel:
                throw AuthError.canceled
            default:
                throw AuthError.failed(laErr.localizedDescription)
            }
        }
    }
}
