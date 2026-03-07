import AuthenticationServices
import Foundation
import UIKit

struct AuthIdentity: Equatable {
    let userId: String
    let fullName: String?
    let email: String?
}

struct AppleSignInResult {
    let identity: AuthIdentity
}

@MainActor
protocol AuthServiceProtocol: AnyObject {
    var currentUser: AppUser? { get }
    var currentIdentity: AuthIdentity? { get }

    func setCurrentUser(_ user: AppUser?)
    func restoreSession(forceSignOutOnLaunch: Bool) async
    func signInWithApple() async throws -> AppleSignInResult
    func authUser() -> AuthIdentity?
    func signOut() async throws
    func deleteAuthAccount() async throws
}

@MainActor
final class AuthService: ObservableObject, AuthServiceProtocol {
    @Published private(set) var currentUser: AppUser?
    @Published private(set) var currentIdentity: AuthIdentity?

    private let appleUserIdKey = "auth.apple.userId"
    private let appleNameKey = "auth.apple.name"
    private let appleEmailKey = "auth.apple.email"

    func restoreSession(forceSignOutOnLaunch: Bool = false) async {
        if forceSignOutOnLaunch {
            clearSession()
            return
        }

        guard let savedUserId = UserDefaults.standard.string(forKey: appleUserIdKey), !savedUserId.isEmpty else {
            currentIdentity = nil
            return
        }

        do {
            let state = try await credentialState(for: savedUserId)
            guard state == .authorized else {
                clearSession()
                return
            }

            let savedName = UserDefaults.standard.string(forKey: appleNameKey)
            let savedEmail = UserDefaults.standard.string(forKey: appleEmailKey)
            currentIdentity = AuthIdentity(userId: savedUserId, fullName: savedName, email: savedEmail)
            AppLog.info("Restored Apple session for user=\(AppLog.redactIdentifier(savedUserId))")
        } catch {
            AppLog.error("Failed restoring Apple session", error: error)
            clearSession()
        }
    }

    func signInWithApple() async throws -> AppleSignInResult {
        let credential = try await Self.performAppleAuthorization()

        let nameFromCredential: String? = {
            guard let fullName = credential.fullName else { return nil }
            let normalized = PersonNameComponentsFormatter().string(from: fullName).trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }()

        let emailFromCredential = credential.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = UserDefaults.standard.string(forKey: appleNameKey)
        let fallbackEmail = UserDefaults.standard.string(forKey: appleEmailKey)

        let identity = AuthIdentity(
            userId: credential.user,
            fullName: nameFromCredential ?? fallbackName,
            email: emailFromCredential ?? fallbackEmail
        )

        persist(identity: identity)
        currentIdentity = identity
        return AppleSignInResult(identity: identity)
    }

    func authUser() -> AuthIdentity? {
        currentIdentity
    }

    func setCurrentUser(_ user: AppUser?) {
        currentUser = user
    }

    func signOut() async throws {
        clearSession()
    }

    func deleteAuthAccount() async throws {
        // Apple account deletion is controlled by Apple ID settings. We clear app session after local data deletion.
        clearSession()
    }

    private func clearSession() {
        currentUser = nil
        currentIdentity = nil
        UserDefaults.standard.removeObject(forKey: appleUserIdKey)
        UserDefaults.standard.removeObject(forKey: appleNameKey)
        UserDefaults.standard.removeObject(forKey: appleEmailKey)
    }

    private func persist(identity: AuthIdentity) {
        UserDefaults.standard.set(identity.userId, forKey: appleUserIdKey)
        if let name = identity.fullName, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: appleNameKey)
        }
        if let email = identity.email, !email.isEmpty {
            UserDefaults.standard.set(email, forKey: appleEmailKey)
        }
    }

    private func credentialState(for userId: String) async throws -> ASAuthorizationAppleIDProvider.CredentialState {
        try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userId) { state, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: state)
            }
        }
    }
}

private final class AppleAuthorizationDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    typealias Continuation = CheckedContinuation<ASAuthorizationAppleIDCredential, Error>

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
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            AuthService.activeAppleDelegate = nil
            continuation.resume(throwing: NSError(
                domain: "StorePass",
                code: 10001,
                userInfo: [NSLocalizedDescriptionKey: "Apple sign-in returned an invalid credential."]
            ))
            return
        }

        AuthService.activeAppleDelegate = nil
        continuation.resume(returning: credential)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        AuthService.activeAppleDelegate = nil
        continuation.resume(throwing: error)
    }
}

extension AuthService {
    fileprivate static var activeAppleDelegate: AppleAuthorizationDelegate?

    static func performAppleAuthorization() async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) in
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = AppleAuthorizationDelegate(continuation: continuation)
            activeAppleDelegate = delegate
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            controller.performRequests()
        }
    }
}
