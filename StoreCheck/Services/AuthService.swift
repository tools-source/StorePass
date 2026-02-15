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
    func restoreSession() async
    func signInWithGoogle() async throws
    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?, email: String?) async throws
    func refreshCurrentUserProfile() async throws -> AppUser
    func signOut() async throws
    func randomNonceString(length: Int) -> String
    func sha256(_ input: String) -> String
    func bootstrapManagerIfNeeded() async throws
}

@MainActor
final class AuthService: ObservableObject, AuthServiceProtocol {
    @Published private(set) var currentUser: AppUser?

    private let auth: Auth
    private let userRepository: UserRepositoryProtocol

    init(auth: Auth = Auth.auth(), userRepository: UserRepositoryProtocol) {
        self.auth = auth
        self.userRepository = userRepository
    }

    func restoreSession() async {
        guard auth.currentUser?.uid != nil else {
            currentUser = nil
            return
        }

        do {
            currentUser = try await refreshCurrentUserProfile()
        } catch {
            currentUser = nil
        }
    }

    func signInWithGoogle() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
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
        let authResult = try await auth.signIn(with: credential)
        currentUser = try await upsertUserFromAuth(provider: "google", fullName: authResult.user.displayName, email: authResult.user.email)
    }

    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?, email: String?) async throws {
        let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: rawNonce, fullName: fullName)
        let authResult = try await auth.signIn(with: credential)
        let fullNameString = [fullName?.givenName, fullName?.familyName].compactMap { $0 }.joined(separator: " ")
        currentUser = try await upsertUserFromAuth(provider: "apple", fullName: fullNameString.isEmpty ? authResult.user.displayName : fullNameString, email: email ?? authResult.user.email)
    }

    func refreshCurrentUserProfile() async throws -> AppUser {
        guard let firebaseUser = auth.currentUser else {
            throw NSError(domain: "StorePass", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Not authenticated."])
        }

        let provider = firebaseUser.providerData.first?.providerID ?? firebaseUser.providerID
        let profile = try await upsertUserFromAuth(provider: normalizedProviderID(provider), fullName: firebaseUser.displayName, email: firebaseUser.email)
        currentUser = profile
        return profile
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

    func bootstrapManagerIfNeeded() async throws {
        guard var user = currentUser else { return }
        let managerCount = try await userRepository.fetchManagersCount()
        if managerCount == 0, !UserDefaults.standard.bool(forKey: "managerBootstrapDone") {
            user.role = UserRole.manager
            try await userRepository.upsertUser(user)
            UserDefaults.standard.set(true, forKey: "managerBootstrapDone")
            currentUser = user
        }
    }

    private func upsertUserFromAuth(provider: String, fullName: String?, email: String?) async throws -> AppUser {
        guard let uid = auth.currentUser?.uid else {
            throw NSError(domain: "StorePass", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Not authenticated."])
        }

        let existing = try await userRepository.fetchUser(id: uid)
        let now = Date()
        var user = existing ?? UserProfile(
            id: uid,
            name: fullName?.isEmpty == false ? fullName! : "StorePass User",
            email: email,
            role: UserRole.employee,
            createdAt: now,
            lastLoginAt: now,
            provider: provider,
            assignedStoreIds: [],
            isActive: true
        )

        user.name = fullName?.isEmpty == false ? fullName! : user.name
        user.email = email ?? user.email
        user.lastLoginAt = now
        user.provider = provider

        try await userRepository.upsertUser(user)
        return user
    }

    private func normalizedProviderID(_ providerID: String) -> String {
        switch providerID {
        case "google.com":
            return "google"
        case "apple.com":
            return "apple"
        default:
            return providerID
        }
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
