import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
import Security
import UIKit

@MainActor
protocol AuthServiceProtocol: AnyObject {
    var currentUser: AppUser? { get }
    func setCurrentUser(_ user: AppUser?)

    func restoreSession(forceSignOutOnLaunch: Bool) async
    func signInWithGoogle() async throws
    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?, email: String?) async throws
    func authUser() -> FirebaseAuth.User?
    func signOut() async throws
    func deleteAuthAccount() async throws
    func randomNonceString(length: Int) -> String
    func sha256(_ input: String) -> String
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

    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?, email: String?) async throws {
        let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: rawNonce, fullName: fullName)
        _ = try await auth.signIn(with: credential)
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

    func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var randomBytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            if status != errSecSuccess {
                fatalError("Unable to generate nonce")
            }

            for byte in randomBytes where remaining > 0 {
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remaining -= 1
                }
            }
        }

        return result
    }

    func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
