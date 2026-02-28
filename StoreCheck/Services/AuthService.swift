import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
import Security
import UIKit

struct AppleSignInResult {
    let fullName: PersonNameComponents?
}

@MainActor
protocol AuthServiceProtocol: AnyObject {
    var currentUser: AppUser? { get }
    func setCurrentUser(_ user: AppUser?)

    func restoreSession(forceSignOutOnLaunch: Bool) async
    func signInWithGoogle() async throws
    func signInWithApple() async throws -> AppleSignInResult
    func signInWithEmail(email: String, password: String) async throws
    func createUserWithEmail(email: String, password: String) async throws
    func authUser() -> FirebaseAuth.User?
    func signOut() async throws
    func deleteAuthAccount() async throws
}

@MainActor
final class AuthService: ObservableObject, AuthServiceProtocol {
    @Published private(set) var currentUser: AppUser?

    private lazy var auth: Auth = authFactory()
    private let authFactory: () -> Auth

    private var firebaseApp: FirebaseApp {
        FirebaseBootstrap.assertConfigured(context: "AuthService.firebaseApp")
        guard let app = FirebaseApp.app() else {
            fatalError("Firebase app is unexpectedly unavailable.")
        }
        return app
    }

    init(authFactory: @escaping () -> Auth = {
        FirebaseBootstrap.assertConfigured(context: "AuthService.authFactory")
        return Auth.auth()
    }) {
        self.authFactory = authFactory
    }

    func restoreSession(forceSignOutOnLaunch: Bool = false) async {
        if forceSignOutOnLaunch {
            try? auth.signOut()
            GIDSignIn.sharedInstance.signOut()
            currentUser = nil
        }
    }

    func signInWithGoogle() async throws {
        FirebaseBootstrap.assertConfigured(context: "AuthService.signInWithGoogle")

        guard let clientID = firebaseApp.options.clientID else {
            throw NSError(domain: "StorePass", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Firebase is not configured. Verify GoogleService-Info.plist is included in the app target."])
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            throw NSError(domain: "StorePass", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Unable to present Google sign-in."])
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else {
            throw NSError(domain: "StorePass", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Google ID token is missing."])
        }

        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
        _ = try await auth.signIn(with: credential)
    }

    func signInWithApple() async throws -> AppleSignInResult {
        FirebaseBootstrap.assertConfigured(context: "AuthService.signInWithApple")

        let nonce = Self.randomNonceString()
        let idTokenData = try await Self.performAppleAuthorization(nonce: nonce)

        guard let idTokenString = String(data: idTokenData.identityToken, encoding: .utf8) else {
            throw NSError(domain: "StorePass", code: 1011, userInfo: [NSLocalizedDescriptionKey: "Unable to decode Apple identity token."])
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: idTokenData.fullName
        )

        _ = try await auth.signIn(with: credential)
        return AppleSignInResult(fullName: idTokenData.fullName)
    }

    func signInWithEmail(email: String, password: String) async throws {
        _ = try await auth.signIn(withEmail: email, password: password)
    }

    func createUserWithEmail(email: String, password: String) async throws {
        _ = try await auth.createUser(withEmail: email, password: password)
    }

    func authUser() -> FirebaseAuth.User? {
        auth.currentUser
    }

    func setCurrentUser(_ user: AppUser?) {
        currentUser = user
    }

    func signOut() async throws {
        let providerIDs = Set(auth.currentUser?.providerData.map(\.providerID) ?? [])

        if providerIDs.contains("google.com") {
            do {
                try await GIDSignIn.sharedInstance.disconnect()
            } catch {
                GIDSignIn.sharedInstance.signOut()
            }
        }

        try auth.signOut()
        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
    }

    func deleteAuthAccount() async throws {
        guard let user = auth.currentUser else { return }
        try await user.delete()
    }
}

private final class AppleAuthorizationDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    typealias Continuation = CheckedContinuation<(identityToken: Data, fullName: PersonNameComponents?), Error>

    private let continuation: Continuation

    init(continuation: Continuation) {
        self.continuation = continuation
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = credential.identityToken else {
            AuthService.activeAppleDelegate = nil
            continuation.resume(throwing: NSError(domain: "StorePass", code: 1012, userInfo: [NSLocalizedDescriptionKey: "Apple identity token is missing."]))
            return
        }
        AuthService.activeAppleDelegate = nil
        continuation.resume(returning: (identityToken: token, fullName: credential.fullName))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        AuthService.activeAppleDelegate = nil
        continuation.resume(throwing: error)
    }
}

extension AuthService {
    fileprivate static var activeAppleDelegate: AppleAuthorizationDelegate?

    static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let errorCode = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            if errorCode != errSecSuccess {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
            }

            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }

    static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }

    static func performAppleAuthorization(nonce: String) async throws -> (identityToken: Data, fullName: PersonNameComponents?) {
        try await withCheckedThrowingContinuation { continuation in
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = AppleAuthorizationDelegate(continuation: continuation)
            activeAppleDelegate = delegate
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            controller.performRequests()
        }
    }
}
