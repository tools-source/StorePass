import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

struct AuthIdentity: Equatable {
    let userId: String
    let fullName: String?
    let email: String?
    let provider: String
}

struct AppleSignInResult {
    let identity: AuthIdentity
}

struct ManualEmployeeSignInResult {
    let identity: AuthIdentity
}

struct EmployeeEmailSignInResult {
    let identity: AuthIdentity
}

@MainActor
protocol AuthServiceProtocol: AnyObject {
    var currentUser: AppUser? { get }
    var currentIdentity: AuthIdentity? { get }

    func setCurrentUser(_ user: AppUser?)
    func restoreSession(forceSignOutOnLaunch: Bool) async
    func signInWithApple() async throws -> AppleSignInResult
    func signInWithApple(authorizationResult: Result<ASAuthorization, Error>) throws -> AppleSignInResult
    func signInManuallyAsEmployee(name: String, email: String) async throws -> ManualEmployeeSignInResult
    func signUpEmployee(name: String, email: String, password: String) async throws -> EmployeeEmailSignInResult
    func signInEmployee(email: String, password: String) async throws -> EmployeeEmailSignInResult
    func authUser() -> AuthIdentity?
    func signOut() async throws
    func deleteAuthAccount() async throws
}

@MainActor
final class AuthService: ObservableObject, AuthServiceProtocol {
    @Published private(set) var currentUser: AppUser?
    @Published private(set) var currentIdentity: AuthIdentity?

    private enum SessionProvider {
        static let apple = "apple"
        static let manualEmployee = "manual.employee"
        static let emailEmployee = "employee.email"
    }

    private let sessionUserIdKey = "auth.session.userId"
    private let sessionNameKey = "auth.session.name"
    private let sessionEmailKey = "auth.session.email"
    private let sessionProviderKey = "auth.session.provider"

    private let appleUserIdKey = "auth.apple.userId"
    private let appleNameKey = "auth.apple.name"
    private let appleEmailKey = "auth.apple.email"

    func restoreSession(forceSignOutOnLaunch: Bool = false) async {
        if forceSignOutOnLaunch {
            clearSession()
            return
        }

        guard let session = loadPersistedSession(), !session.userId.isEmpty else {
            currentIdentity = nil
            return
        }

        if session.provider == SessionProvider.manualEmployee || session.provider == SessionProvider.emailEmployee {
            currentIdentity = AuthIdentity(
                userId: session.userId,
                fullName: session.name,
                email: session.email,
                provider: session.provider
            )
            AppLog.info("Restored manual employee session for user=\(AppLog.redactIdentifier(session.userId))")
            return
        }

        do {
            let state = try await credentialState(for: session.userId)
            guard state == .authorized else {
                clearSession()
                return
            }

            currentIdentity = AuthIdentity(
                userId: session.userId,
                fullName: session.name,
                email: session.email,
                provider: SessionProvider.apple
            )
            AppLog.info("Restored Apple session for user=\(AppLog.redactIdentifier(session.userId))")
        } catch {
            AppLog.error("Failed restoring Apple session", error: error)
            clearSession()
        }
    }

    func signInWithApple() async throws -> AppleSignInResult {
        AppLog.info("Apple sign-in started (async request)")
        let credential = try await Self.performAppleAuthorization()
        let result = finalizeAppleSignIn(with: credential)
        AppLog.info("Apple sign-in completed for user=\(AppLog.redactIdentifier(result.identity.userId))")
        return result
    }

    func signInWithApple(authorizationResult: Result<ASAuthorization, Error>) throws -> AppleSignInResult {
        AppLog.info("Apple sign-in started (button completion path)")
        let authorization: ASAuthorization
        switch authorizationResult {
        case .success(let value):
            authorization = value
        case .failure(let error):
            AppLog.error("Apple sign-in failed before credential parsing", error: error)
            throw error
        }

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            AppLog.error("Apple sign-in returned non-AppleID credential")
            throw NSError(
                domain: "StorePass",
                code: 10001,
                userInfo: [NSLocalizedDescriptionKey: "Apple sign-in returned an invalid credential."]
            )
        }

        let result = finalizeAppleSignIn(with: credential)
        AppLog.info("Apple sign-in completed for user=\(AppLog.redactIdentifier(result.identity.userId))")
        return result
    }

    func signInManuallyAsEmployee(name: String, email: String) async throws -> ManualEmployeeSignInResult {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw CloudKitClientError.invalidData("Enter your name to continue as an employee.")
        }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEmail(normalizedEmail) else {
            throw CloudKitClientError.invalidData("Enter a valid employee email address.")
        }

        let identity = AuthIdentity(
            userId: manualEmployeeUserId(for: normalizedEmail),
            fullName: normalizedName,
            email: normalizedEmail,
            provider: SessionProvider.manualEmployee
        )

        persist(identity: identity)
        currentIdentity = identity
        AppLog.info("Manual employee sign-in completed for user=\(AppLog.redactIdentifier(identity.userId))")
        return ManualEmployeeSignInResult(identity: identity)
    }


    func signUpEmployee(name: String, email: String, password: String) async throws -> EmployeeEmailSignInResult {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw CloudKitClientError.invalidData("Enter your name to create an employee account.")
        }

        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEmail(normalizedEmail) else {
            throw CloudKitClientError.invalidData("Enter a valid employee email address.")
        }

        try EmployeeCredentialStore.register(email: normalizedEmail, password: password)

        let identity = AuthIdentity(
            userId: employeeEmailUserId(for: normalizedEmail),
            fullName: normalizedName,
            email: normalizedEmail,
            provider: SessionProvider.emailEmployee
        )

        persist(identity: identity)
        currentIdentity = identity
        AppLog.info("Employee email sign-up completed for user=\(AppLog.redactIdentifier(identity.userId))")
        return EmployeeEmailSignInResult(identity: identity)
    }

    func signInEmployee(email: String, password: String) async throws -> EmployeeEmailSignInResult {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidEmail(normalizedEmail) else {
            throw CloudKitClientError.invalidData("Enter a valid employee email address.")
        }

        try EmployeeCredentialStore.authenticate(email: normalizedEmail, password: password)

        let identity = AuthIdentity(
            userId: employeeEmailUserId(for: normalizedEmail),
            fullName: nil,
            email: normalizedEmail,
            provider: SessionProvider.emailEmployee
        )

        persist(identity: identity)
        currentIdentity = identity
        AppLog.info("Employee email sign-in completed for user=\(AppLog.redactIdentifier(identity.userId))")
        return EmployeeEmailSignInResult(identity: identity)
    }
    private func finalizeAppleSignIn(with credential: ASAuthorizationAppleIDCredential) -> AppleSignInResult {
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
            email: emailFromCredential ?? fallbackEmail,
            provider: SessionProvider.apple
        )

        persist(identity: identity)
        currentIdentity = identity
        AppLog.info("Auth identity persisted for user=\(AppLog.redactIdentifier(identity.userId))")
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
        if let identity = currentIdentity,
           identity.provider == SessionProvider.emailEmployee {
            EmployeeCredentialStore.deleteCredential(email: identity.email)
        }
        // Apple account deletion is controlled by Apple ID settings. We clear app session after local data deletion.
        clearSession()
    }

    private func clearSession() {
        if let currentIdentity {
            AppLog.info("Clearing auth session for user=\(AppLog.redactIdentifier(currentIdentity.userId))")
        } else {
            AppLog.info("Clearing auth session with no active identity")
        }
        currentUser = nil
        currentIdentity = nil
        UserDefaults.standard.removeObject(forKey: sessionUserIdKey)
        UserDefaults.standard.removeObject(forKey: sessionNameKey)
        UserDefaults.standard.removeObject(forKey: sessionEmailKey)
        UserDefaults.standard.removeObject(forKey: sessionProviderKey)
        UserDefaults.standard.removeObject(forKey: appleUserIdKey)
        UserDefaults.standard.removeObject(forKey: appleNameKey)
        UserDefaults.standard.removeObject(forKey: appleEmailKey)
    }

    private func persist(identity: AuthIdentity) {
        UserDefaults.standard.set(identity.userId, forKey: sessionUserIdKey)
        UserDefaults.standard.set(identity.provider, forKey: sessionProviderKey)
        if let name = identity.fullName, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: sessionNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionNameKey)
        }
        if let email = identity.email, !email.isEmpty {
            UserDefaults.standard.set(email, forKey: sessionEmailKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionEmailKey)
        }

        if identity.provider == SessionProvider.apple {
            UserDefaults.standard.set(identity.userId, forKey: appleUserIdKey)
            if let name = identity.fullName, !name.isEmpty {
                UserDefaults.standard.set(name, forKey: appleNameKey)
            }
            if let email = identity.email, !email.isEmpty {
                UserDefaults.standard.set(email, forKey: appleEmailKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: appleUserIdKey)
            UserDefaults.standard.removeObject(forKey: appleNameKey)
            UserDefaults.standard.removeObject(forKey: appleEmailKey)
        }
        AppLog.info("Stored auth identity in UserDefaults for user=\(AppLog.redactIdentifier(identity.userId)) provider=\(identity.provider)")
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

    private func loadPersistedSession() -> (userId: String, name: String?, email: String?, provider: String)? {
        if let userId = UserDefaults.standard.string(forKey: sessionUserIdKey), !userId.isEmpty {
            return (
                userId: userId,
                name: UserDefaults.standard.string(forKey: sessionNameKey),
                email: UserDefaults.standard.string(forKey: sessionEmailKey),
                provider: UserDefaults.standard.string(forKey: sessionProviderKey) ?? SessionProvider.apple
            )
        }

        if let legacyAppleUserId = UserDefaults.standard.string(forKey: appleUserIdKey), !legacyAppleUserId.isEmpty {
            return (
                userId: legacyAppleUserId,
                name: UserDefaults.standard.string(forKey: appleNameKey),
                email: UserDefaults.standard.string(forKey: appleEmailKey),
                provider: SessionProvider.apple
            )
        }

        return nil
    }

    private func manualEmployeeUserId(for email: String) -> String {
        let digest = SHA256.hash(data: Data(email.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "manual_employee_\(hash)"
    }

    private func employeeEmailUserId(for email: String) -> String {
        let digest = SHA256.hash(data: Data(email.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "employee_email_\(hash)"
    }

    private func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && parts[1].contains(".")
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
