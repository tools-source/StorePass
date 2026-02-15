import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFirestore
import Foundation
import GoogleSignIn
import UIKit
import Security

protocol AuthServiceProtocol {
    var currentUser: AppUser? { get }
    func restoreSession() async
    func signInWithGoogle() async throws
    func signInWithApple() async throws
    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?, email: String?) async throws
    func signOut() throws
    func getCurrentUser() async throws -> AppUser?
    func createOrUpdateUserInFirestore(
        uid: String,
        name: String?,
        email: String?,
        provider: String,
        defaultRole: UserRole
    ) async throws -> AppUser
    func randomNonceString(length: Int) -> String
    func sha256(_ input: String) -> String
}

@MainActor
final class AuthService: ObservableObject, AuthServiceProtocol {
    @Published private(set) var currentUser: AppUser?

    private let db: Firestore
    private let auth: Auth

    init(auth: Auth = Auth.auth(), db: Firestore = Firestore.firestore()) {
        self.auth = auth
        self.db = db
    }

    func restoreSession() async {
        currentUser = try? await getCurrentUser()
    }

    func signInWithGoogle() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw NSError(domain: "StoreCheck", code: 2000, userInfo: [NSLocalizedDescriptionKey: "Missing Firebase client ID."])
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        guard let presentingViewController = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            throw NSError(domain: "StoreCheck", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Unable to find a presenting view controller."])
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
        let user = result.user
        guard let idToken = user.idToken?.tokenString else {
            throw NSError(domain: "StoreCheck", code: 2002, userInfo: [NSLocalizedDescriptionKey: "Google ID token not found."])
        }

        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: user.accessToken.tokenString)
        let authResult = try await auth.signIn(with: credential)
        let profile = try await createOrUpdateUserInFirestore(
            uid: authResult.user.uid,
            name: authResult.user.displayName,
            email: authResult.user.email,
            provider: "google",
            defaultRole: .employee
        )
        currentUser = profile
    }

    func signInWithApple() async throws {
        throw NSError(
            domain: "StoreCheck",
            code: 2003,
            userInfo: [NSLocalizedDescriptionKey: "Use signInWithApple(idToken:rawNonce:fullName:email:) from the Apple Sign-In callback."]
        )
    }

    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?, email: String?) async throws {
        let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: rawNonce, fullName: fullName)
        let authResult = try await auth.signIn(with: credential)
        let fallbackName = [fullName?.givenName, fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = try await createOrUpdateUserInFirestore(
            uid: authResult.user.uid,
            name: fallbackName.isEmpty ? authResult.user.displayName : fallbackName,
            email: email ?? authResult.user.email,
            provider: "apple",
            defaultRole: .employee
        )
        currentUser = profile
    }

    func signOut() throws {
        GIDSignIn.sharedInstance.signOut()
        try auth.signOut()
        currentUser = nil
    }

    func getCurrentUser() async throws -> AppUser? {
        guard let user = auth.currentUser else { return nil }
        let ref = db.collection("users").document(user.uid)
        let snapshot = try await ref.getDocument()
        if snapshot.exists {
            return try snapshot.data(as: AppUser.self)
        }

        return try await createOrUpdateUserInFirestore(
            uid: user.uid,
            name: user.displayName,
            email: user.email,
            provider: user.providerID,
            defaultRole: .employee
        )
    }

    func createOrUpdateUserInFirestore(
        uid: String,
        name: String?,
        email: String?,
        provider: String,
        defaultRole: UserRole = .employee
    ) async throws -> AppUser {
        let ref = db.collection("users").document(uid)
        let snapshot = try await ref.getDocument()

        let now = Date()
        let safeName = (name?.isEmpty == false ? name : "StoreCheck User") ?? "StoreCheck User"
        let safeEmail = (email?.isEmpty == false ? email : "unknown@privaterelay.appleid.com") ?? "unknown@privaterelay.appleid.com"

        var user: AppUser
        if snapshot.exists, let existing = try? snapshot.data(as: AppUser.self) {
            user = existing
            if !safeName.isEmpty { user.name = safeName }
            if !safeEmail.isEmpty { user.email = safeEmail }
            user.lastLoginAt = now
            user.provider = provider
        } else {
            user = AppUser(
                id: uid,
                name: safeName,
                email: safeEmail,
                role: defaultRole,
                createdAt: now,
                lastLoginAt: now,
                provider: provider,
                assignedStoreIds: [],
                isActive: true
            )
        }

        try ref.setData(from: user, merge: true)
        return user
    }

    func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms: [UInt8] = Array(repeating: 0, count: 16)
            let errorCode = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            if errorCode != errSecSuccess {
                fatalError("Unable to generate nonce. OSStatus \(errorCode)")
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

    func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }
}
