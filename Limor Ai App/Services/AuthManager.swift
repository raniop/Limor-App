import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AuthManager: ObservableObject {
    enum State { case loading, signedOut, signedIn }

    @Published private(set) var state: State = .loading
    @Published private(set) var displayName: String?
    @Published private(set) var photoB64: String?
    @Published private(set) var email: String?

    var token: String? { nil }

    private var stateHandle: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?

    init() {
        stateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.applyAuthState(user: user)
            }
        }
    }

    deinit {
        if let handle = stateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    /// Restores the previous Google sign-in (if one exists) so we don't prompt
    /// the user to authenticate again on every cold launch. Firebase Auth
    /// already persists across launches; GoogleSignIn doesn't unless we ask.
    /// Also re-derives the user's preferred email/calendar source from the
    /// scopes that come back — after a fresh install, App Group UserDefaults
    /// is wiped but Google's grant survives, so we should re-flip the toggle
    /// back to Google instead of leaving it at the default.
    func bootstrap() async {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            print("[google] restored session for \(user.profile?.email ?? "unknown")")
            restoreSourcePreferencesFromScopes()
        } catch {
            print("[google] restore failed: \(error.localizedDescription)")
        }
    }

    /// If the user previously connected Gmail (the OAuth scope is still
    /// granted) but the local toggle came back as the unset default after a
    /// reinstall, auto-flip it to .google so they don't have to re-pick it.
    /// Calendar is intentionally NOT auto-flipped — its default is .apple,
    /// which can be either the default OR an explicit user choice; we can't
    /// tell the two apart, so we leave that toggle alone.
    private func restoreSourcePreferencesFromScopes() {
        let granted = GoogleAPIs.grantedScopes()
        if granted.contains(GoogleAPIs.gmailReadOnlyScope), SharedStore.emailSource == .none {
            SharedStore.emailSource = .google
            print("[google] restored emailSource → .google (gmail scope present)")
        }
    }

    // MARK: - Sign in with Apple → Firebase

    func prepareSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    func completeSignIn(authorization: ASAuthorization) async throws {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let identityTokenData = credential.identityToken,
            let identityToken = String(data: identityTokenData, encoding: .utf8),
            let nonce = currentNonce
        else {
            throw AuthError.missingIdentityToken
        }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: identityToken,
            rawNonce: nonce,
            fullName: credential.fullName
        )

        _ = try await Auth.auth().signIn(with: firebaseCredential)
        currentNonce = nil

        let nameParts = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !nameParts.isEmpty {
            let fullName = nameParts.joined(separator: " ")
            if let req = Auth.auth().currentUser?.createProfileChangeRequest() {
                req.displayName = fullName
                try? await req.commitChanges()
            }
            try? await APIClient.shared.setDisplayName(fullName)
        }
    }

    // MARK: - Sign in with Google → Firebase

    func signInWithGoogle() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw AuthError.googleConfigMissing
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

        guard let presenting = topViewController() else {
            throw AuthError.noPresentingViewController
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingIdentityToken
        }
        let accessToken = result.user.accessToken.tokenString

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: accessToken
        )
        _ = try await Auth.auth().signIn(with: credential)

        if let name = result.user.profile?.name, !name.isEmpty {
            if let req = Auth.auth().currentUser?.createProfileChangeRequest() {
                req.displayName = name
                try? await req.commitChanges()
            }
            try? await APIClient.shared.setDisplayName(name)
        }
    }

    // MARK: - Sign out

    func signOut() {
        Task { try? await PushManager.shared.unregisterCurrentToken() }
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
    }

    func currentIdToken() async -> String? {
        guard let user = Auth.auth().currentUser else { return nil }
        return try? await user.idTokenAsync()
    }

    // MARK: - Internal

    private func applyAuthState(user: User?) {
        if let user {
            displayName = user.displayName
            email = user.email
            photoB64 = SharedStore.photoB64    // optimistic from cache, refreshed below
            SharedStore.bearer = nil
            if let raw = Bundle.main.object(forInfoDictionaryKey: "LIMOR_API_BASE_URL") as? String,
               let url = URL(string: raw) {
                SharedStore.baseURL = url
            }
            state = .signedIn
            // Notifications prompt is part of OnboardingView on first run.
            // Once onboarding has run, refresh the request silently — if the
            // user already granted, this is a no-op; if they denied, no UI.
            if SharedStore.onboardingCompleted {
                Task { await PushManager.shared.requestPermissionIfNeeded() }
            }
            Task { await PushManager.shared.uploadIfPossible() }
            Task { await refreshProfileFromBackend() }
        } else {
            displayName = nil
            photoB64 = nil
            email = nil
            SharedStore.clear()
            state = .signedOut
        }
    }

    func refreshProfileFromBackend() async {
        do {
            let profile = try await APIClient.shared.getMe()
            displayName = profile.display_name ?? displayName
            email = profile.email ?? email
            photoB64 = profile.photo_b64
            SharedStore.photoB64 = profile.photo_b64
        } catch {
            // Silent — view-level errors handle individual requests.
        }
    }

    func setProfilePhoto(jpegB64: String?) async throws {
        try await APIClient.shared.updateProfile(displayName: nil, photoB64: jpegB64 ?? "")
        photoB64 = jpegB64
        SharedStore.photoB64 = jpegB64
    }

    func setDisplayName(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await APIClient.shared.setDisplayName(trimmed)
        displayName = trimmed
        if let req = Auth.auth().currentUser?.createProfileChangeRequest() {
            req.displayName = trimmed
            try? await req.commitChanges()
        }
    }

    // MARK: - Nonce helpers

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            let randoms: [UInt8] = (0 ..< 16).map { _ in
                var random: UInt8 = 0
                let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                precondition(status == errSecSuccess)
                return random
            }
            for random in randoms {
                if remainingLength == 0 { break }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard let root = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windowScene?.windows.first?.rootViewController else { return nil }
        return topMost(of: root)
    }

    private func topMost(of viewController: UIViewController) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return topMost(of: presented)
        }
        if let nav = viewController as? UINavigationController, let visible = nav.visibleViewController {
            return topMost(of: visible)
        }
        if let tab = viewController as? UITabBarController, let selected = tab.selectedViewController {
            return topMost(of: selected)
        }
        return viewController
    }
}

enum AuthError: LocalizedError {
    case missingIdentityToken
    case googleConfigMissing
    case noPresentingViewController

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken: return "Apple/Google לא החזירו identity token."
        case .googleConfigMissing:  return "GoogleService-Info.plist חסר או פגום."
        case .noPresentingViewController: return "לא הצלחתי לפתוח את חלון הכניסה של Google."
        }
    }
}

private extension User {
    func idTokenAsync() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.getIDToken { token, error in
                if let token { continuation.resume(returning: token) }
                else { continuation.resume(throwing: error ?? AuthError.missingIdentityToken) }
            }
        }
    }
}
