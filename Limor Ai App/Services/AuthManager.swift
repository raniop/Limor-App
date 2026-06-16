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
    /// Provider IDs linked to the current account ("apple.com", "google.com").
    /// Drives the "link account" UI in Settings.
    @Published private(set) var linkedProviders: Set<String> = []

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
        // Microsoft side: wire up MSAL's URL handler + load cached account
        // from keychain. No network round-trip — safe regardless of whether
        // the user has ever connected Outlook.
        MicrosoftAPIs.bootstrap()

        if GIDSignIn.sharedInstance.hasPreviousSignIn() {
            do {
                let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                print("[google] restored session for \(user.profile?.email ?? "unknown")")
            } catch {
                print("[google] restore failed: \(error.localizedDescription)")
            }
        }
        restoreSourcePreferencesFromScopes()
    }

    /// If the user previously connected Gmail or Outlook (the OAuth scope is
    /// still granted) but the local toggle came back unset after a reinstall,
    /// auto-add each connected provider to the email sources set so they
    /// don't have to re-pick. Additive — never removes an existing source.
    /// Calendar is intentionally NOT auto-restored — its default already
    /// includes Apple, which can be either the default OR an explicit user
    /// choice; we can't tell the two apart, so we leave that set alone.
    private func restoreSourcePreferencesFromScopes() {
        var sources = SharedStore.emailSources
        let beforeCount = sources.count

        if GoogleAPIs.grantedScopes().contains(GoogleAPIs.gmailReadOnlyScope) {
            sources.insert(.google)
        }
        if MicrosoftAPIs.grantedScopes().contains(MicrosoftAPIs.mailReadScope),
           MicrosoftAPIs.isSignedIn() {
            sources.insert(.microsoft)
        }

        if sources.count > beforeCount {
            SharedStore.emailSources = sources
            let names = sources.map(\.rawValue).sorted().joined(separator: "+")
            print("[auth] restored emailSources → \(names)")
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

    // MARK: - Account linking (same account across providers)
    //
    // Linking lets one user sign in with *either* Apple or Google and land on
    // the same account — e.g. someone who signed up with Apple's hidden relay
    // email on their iPhone can link Google here, then sign in with Google on
    // an iPad and reach the very same account + data. We capture the real
    // identity via OAuth (no manual email typing), which is reliable: Firebase
    // stores the extra provider on this uid, so a later sign-in with it
    // resolves back to this account.

    func refreshLinkedProviders() {
        linkedProviders = Set(Auth.auth().currentUser?.providerData.map(\.providerID) ?? [])
    }

    /// Link a Google identity to the current account.
    func linkGoogle() async throws {
        guard let user = Auth.auth().currentUser else { throw AuthError.notSignedIn }
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
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        do { _ = try await user.link(with: credential) }
        catch { throw mapLinkError(error) }
        refreshLinkedProviders()
    }

    /// Prepare an Apple authorization request for *linking* (reuses the same
    /// nonce/scope setup as sign-in).
    func prepareLinkRequest(_ request: ASAuthorizationAppleIDRequest) {
        prepareSignInRequest(request)
    }

    /// Link an Apple identity to the current account.
    func completeAppleLink(authorization: ASAuthorization) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthError.notSignedIn }
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let identityTokenData = credential.identityToken,
            let identityToken = String(data: identityTokenData, encoding: .utf8),
            let nonce = currentNonce
        else { throw AuthError.missingIdentityToken }

        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: identityToken,
            rawNonce: nonce,
            fullName: credential.fullName
        )
        currentNonce = nil
        do { _ = try await user.link(with: firebaseCredential) }
        catch { throw mapLinkError(error) }
        refreshLinkedProviders()
    }

    private func mapLinkError(_ error: Error) -> Error {
        let code = (error as NSError).code
        if code == AuthErrorCode.providerAlreadyLinked.rawValue { return AuthError.alreadyLinked }
        if code == AuthErrorCode.credentialAlreadyInUse.rawValue
            || code == AuthErrorCode.emailAlreadyInUse.rawValue {
            return AuthError.linkConflict
        }
        return error
    }

    // MARK: - Sign out

    func signOut() {
        Task { try? await PushManager.shared.unregisterCurrentToken() }
        GIDSignIn.sharedInstance.signOut()
        MicrosoftAPIs.signOut()
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
            if let raw = Bundle.main.object(forInfoDictionaryKey: "LIMOR_API_BASE_URL") as? String,
               let url = URL(string: raw) {
                SharedStore.baseURL = url
            }
            state = .signedIn
            refreshLinkedProviders()
            // Eagerly mint a Firebase ID token so the App Group bearer is
            // populated for the Widget + Share Extension right after sign-in,
            // rather than waiting for the next outgoing API call to do it.
            Task { _ = await APIClient.shared.refreshSharedBearer() }
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
        await refreshGenderFromBackend()
    }

    /// Pull the user's "מגדר" profile fact and mirror it into the App Group
    /// so Hebrew strings (in the main app *and* the Share Extension) can
    /// match the user's grammatical gender. Backfills existing users who
    /// finished the intro before we started writing the App-Group key.
    private func refreshGenderFromBackend() async {
        guard let resp = try? await APIClient.shared.profileFacts() else { return }
        let genderFact = resp.facts.first { $0.label == "מגדר" }
        if let raw = genderFact?.value, let gender = UserGender.fromHebrewLabel(raw) {
            UserGender.store(gender)
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
    case notSignedIn
    case alreadyLinked
    case linkConflict

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken: return tr("Apple/Google לא החזירו identity token.", "Apple/Google didn't return an identity token.")
        case .googleConfigMissing:  return tr("GoogleService-Info.plist חסר או פגום.", "GoogleService-Info.plist is missing or corrupted.")
        case .noPresentingViewController: return tr("לא הצלחתי לפתוח את חלון הכניסה של Google.", "Couldn't open the Google sign-in window.")
        case .notSignedIn: return tr("צריך להיות מחובר כדי לקשר חשבון.", "You need to be signed in to link an account.")
        case .alreadyLinked: return tr("החשבון הזה כבר מקושר.", "This account is already linked.")
        case .linkConflict: return tr("החשבון הזה כבר משויך למשתמש אחר ב-Limor. אם זה אתה — התחבר איתו ישירות, או נתק אותו שם קודם.", "This account is already linked to another user on Limor. If that's you — sign in with it directly, or unlink it there first.")
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
