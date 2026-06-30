import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import FirebaseCore
import FirebaseAuth

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@MainActor
@Observable
final class AuthService {
    static let shared = AuthService()

    var isAuthenticated: Bool = (Auth.auth().currentUser != nil)
    var lastError: String?

    // Set true only when the user completes an INTERACTIVE sign-in or
    // sign-up (not on launch-time session restore, which initializes
    // `isAuthenticated` above without going through these methods).
    // Consumed by the Study tab to kick off the first-run coach tour on
    // every fresh login. Transient — not persisted.
    var didJustAuthenticate: Bool = false

    private var currentNonce: String?

    private init() {}

    // MARK: - Apple Sign-In

    /// Call from `SignInWithAppleButton(onRequest:)`.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Call from `SignInWithAppleButton(onCompletion:)`.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken,
                  let idTokenString = String(data: identityToken, encoding: .utf8) else {
                throw AuthError.invalidCredential
            }
            guard let nonce = currentNonce else {
                throw AuthError.missingNonce
            }
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: credential.fullName
            )
            _ = try await Auth.auth().signIn(with: firebaseCredential)
            isAuthenticated = true
            didJustAuthenticate = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Google Sign-In

    /// Triggers Google Sign-In and completes Firebase sign-in with the returned credential.
    /// Requires the `GoogleSignIn` Swift Package (https://github.com/google/GoogleSignIn-iOS).
    func signInWithGoogle() async {
        #if canImport(GoogleSignIn)
        do {
            guard let clientID = FirebaseApp.app()?.options.clientID else {
                throw AuthError.missingClientID
            }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)

            guard let presentingVC = Self.topViewController() else {
                throw AuthError.noPresentationContext
            }

            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingVC)
            guard let idToken = result.user.idToken?.tokenString else {
                throw AuthError.invalidCredential
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            _ = try await Auth.auth().signIn(with: credential)
            isAuthenticated = true
            didJustAuthenticate = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        #else
        lastError = "Google Sign-In not available. Add the GoogleSignIn Swift Package to enable it."
        #endif
    }

    // MARK: - Anonymous

    /// Placeholder path for the Phone / Email buttons until real flows ship.
    /// Creates an anonymous Firebase user so we have a UID to attach onboarding
    /// data and decks to. A later real Apple/Google/phone/email sign-in can
    /// link to this anonymous account via `linkWithCredential` to preserve
    /// pre-auth data.
    func signInAnonymously() async {
        do {
            _ = try await Auth.auth().signInAnonymously()
            isAuthenticated = true
            didJustAuthenticate = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Phone (SMS code)
    //
    // Firebase phone auth flow:
    //   1. Call `sendPhoneVerification(to:)` with an E.164 number → returns
    //      a `verificationID` string (good for ~5 minutes). Firebase sends
    //      an SMS to the user with a 6-digit code.
    //   2. User types the code into the UI; call `signInWithPhone(...)`.
    //
    // Requires Phone sign-in to be enabled in Firebase Console →
    // Authentication → Sign-in method, and the project's APNs key /
    // reCAPTCHA fallback to be configured. Test phone numbers
    // pre-registered in Firebase Console bypass SMS delivery for App
    // Store review.

    @discardableResult
    func sendPhoneVerification(to phoneNumber: String) async -> String? {
        do {
            let verificationID = try await PhoneAuthProvider.provider()
                .verifyPhoneNumber(phoneNumber, uiDelegate: nil)
            lastError = nil
            return verificationID
        } catch {
            lastError = friendlyAuthMessage(for: error)
            return nil
        }
    }

    @discardableResult
    func signInWithPhone(verificationID: String, code: String) async -> Bool {
        let credential = PhoneAuthProvider.provider().credential(
            withVerificationID: verificationID,
            verificationCode: code
        )
        do {
            _ = try await Auth.auth().signIn(with: credential)
            isAuthenticated = true
            didJustAuthenticate = true
            lastError = nil
            return true
        } catch {
            lastError = friendlyAuthMessage(for: error)
            return false
        }
    }

    // MARK: - Email + Password
    //
    // Real (non-anonymous) email/password auth. Requires Email/Password
    // sign-in to be enabled in Firebase Console → Authentication →
    // Sign-in method, otherwise both calls fail with FIRAuthErrorCode
    // .operationNotAllowed ("This operation is restricted to
    // administrators only"). Returns true on success so the caller can
    // dismiss its UI without re-reading `isAuthenticated`.

    @discardableResult
    func signInWithEmail(_ email: String, password: String) async -> Bool {
        do {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
            isAuthenticated = true
            didJustAuthenticate = true
            lastError = nil
            return true
        } catch {
            lastError = friendlyAuthMessage(for: error)
            return false
        }
    }

    @discardableResult
    func createUserWithEmail(_ email: String, password: String) async -> Bool {
        do {
            _ = try await Auth.auth().createUser(withEmail: email, password: password)
            isAuthenticated = true
            didJustAuthenticate = true
            lastError = nil
            return true
        } catch {
            lastError = friendlyAuthMessage(for: error)
            return false
        }
    }

    // Maps the most common FirebaseAuthError codes onto copy that's
    // actionable for the user. Everything else falls through to
    // `localizedDescription` so we don't accidentally swallow a useful
    // error message we haven't seen yet.
    private func friendlyAuthMessage(for error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == AuthErrorDomain,
              let code = AuthErrorCode(rawValue: ns.code) else {
            return error.localizedDescription
        }
        switch code {
        case .operationNotAllowed:
            return "Email sign-in isn't enabled for this app yet. Enable Email/Password in Firebase Console → Authentication → Sign-in method."
        case .invalidEmail:
            return "That email address doesn't look right."
        case .emailAlreadyInUse:
            return "An account with that email already exists. Try signing in instead."
        case .weakPassword:
            return "That password is too weak — use at least 6 characters."
        case .userNotFound:
            return "No account found for that email. Tap Create Account below."
        case .wrongPassword, .invalidCredential:
            return "That email and password don't match. Try again."
        case .networkError:
            return "Couldn't reach the network. Check your connection and try again."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Sign out

    func signOut() {
        try? Auth.auth().signOut()
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        isAuthenticated = false
    }

    // MARK: - Account deletion

    // Order matters: Firestore data is purged first so the deletion
    // is observable even if the auth-side delete trips Firebase's
    // recent-login requirement. If `user.delete()` throws
    // `requiresRecentLogin`, the caller surfaces the "sign out and
    // try again" prompt; on the retry the data step is a fast no-op
    // and the auth delete completes once reauth has happened.
    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }
        let uid = user.uid
        try await UserService.deleteAllUserData(uid: uid)
        try await user.delete()
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
        isAuthenticated = false
        lastError = nil
    }

    // MARK: - Helpers

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.windows.first(where: \.isKeyWindow),
              var top = window.rootViewController else {
            return nil
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var byte: UInt8 = 0
                _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
                return byte
            }
            for random in randoms {
                if remaining == 0 { break }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remaining -= 1
                }
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

enum AuthError: LocalizedError {
    case invalidCredential
    case missingNonce
    case missingClientID
    case noPresentationContext
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidCredential:     return "Unable to extract identity token."
        case .missingNonce:          return "Sign-in state was lost — please try again."
        case .missingClientID:       return "Firebase client ID is missing from GoogleService-Info.plist."
        case .noPresentationContext: return "Could not find a window to present sign-in from."
        case .notAuthenticated:      return "You need to be signed in to do that."
        }
    }
}
