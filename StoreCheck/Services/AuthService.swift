import FirebaseAuth
import FirebaseCore
import Foundation
import GoogleSignIn
import UIKit

@MainActor
protocol AuthServiceProtocol: AnyObject {
    var currentUser: AppUser? { get }
    func setCurrentUser(_ user: AppUser?)

    func restoreSession(forceSignOutOnLaunch: Bool) async
    func signInWithGoogle() async throws
    func signInWithEmail(email: String, password: String) async throws
    func createUserWithEmail(email: String, password: String) async throws
    func sendSignInLink(toEmail email: String) async throws
    func isSignIn(withEmailLink link: String) -> Bool
    func signIn(withEmail email: String, link: String) async throws
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

    func signInWithEmail(email: String, password: String) async throws {
        _ = try await auth.signIn(withEmail: email, password: password)
    }

    func createUserWithEmail(email: String, password: String) async throws {
        _ = try await auth.createUser(withEmail: email, password: password)
    }

    func sendSignInLink(toEmail email: String) async throws {
        let settings = try emailLinkActionCodeSettings()
        try await auth.sendSignInLink(toEmail: email, actionCodeSettings: settings)
    }

    func isSignIn(withEmailLink link: String) -> Bool {
        auth.isSignIn(withEmailLink: link)
    }

    func signIn(withEmail email: String, link: String) async throws {
        _ = try await auth.signIn(withEmail: email, link: link)
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

    private func emailLinkActionCodeSettings() throws -> ActionCodeSettings {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw NSError(domain: "StorePass", code: 1005, userInfo: [NSLocalizedDescriptionKey: "Missing app bundle identifier."])
        }

        guard let continueURL = URL(string: "https://storecheck-6fdc8.firebaseapp.com/emailSignIn") else {
            throw NSError(domain: "StorePass", code: 1006, userInfo: [NSLocalizedDescriptionKey: "Unable to determine Firebase continue URL for email link sign-in."])
        }

        let settings = ActionCodeSettings()
        settings.handleCodeInApp = true
        settings.setIOSBundleID(bundleIdentifier)
        settings.url = continueURL
        return settings
    }
}
