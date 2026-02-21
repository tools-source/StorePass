import AuthenticationServices
import FirebaseAuth
import FirebaseFirestore
import Foundation
import SwiftUI

@MainActor
final class AuthViewModel: ObservableObject {
    enum AuthState: Equatable {
        case signedOut
        case signedIn(userId: String)
    }

    @Published var authState: AuthState = .signedOut
    @Published var requestedRole: UserRole?
    @Published var resolvedRole: UserRole?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showManagerAccessRequired = false
    @Published var managerAccessMessage = "This account does not have manager access. Please switch to Employee mode or ask an admin to update your role."
    @Published var showEmployeeSetupRequired = false
    @Published private(set) var currentUser: AppUser?

    @AppStorage("lastRequestedRole") private var lastRequestedRoleRaw: String = ""

    private let authService: AuthService
    private let roleProfileRepository: RoleProfileRepositoryProtocol
    private(set) var currentNonce: String?

    init(authService: AuthService, roleProfileRepository: RoleProfileRepositoryProtocol) {
        self.authService = authService
        self.roleProfileRepository = roleProfileRepository
        self.requestedRole = UserRole(rawValue: lastRequestedRoleRaw)
    }

    func restoreSession(forceSignOutOnLaunch: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        await authService.restoreSession(forceSignOutOnLaunch: forceSignOutOnLaunch)

        guard authService.authUser() != nil else {
            clearState()
            return
        }

        do {
            try await resolveProfileAndRoute(requestedRole: UserRole(rawValue: lastRequestedRoleRaw), isSessionRestore: true)
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signInWithGoogle(requestedRole: UserRole) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await authService.signInWithGoogle()
            try await resolveProfileAndRoute(requestedRole: requestedRole, isSessionRestore: false, provider: "google")
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = authService.randomNonceString(length: 32)
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = authService.sha256(nonce)
    }

    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>, requestedRole: UserRole) {
        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                guard case .success(let authorization) = result,
                      let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let nonce = currentNonce,
                      let tokenData = credential.identityToken,
                      let idToken = String(data: tokenData, encoding: .utf8) else {
                    throw NSError(domain: "StorePass", code: 2001, userInfo: [NSLocalizedDescriptionKey: "Apple sign in failed. Please try again."])
                }

                try await authService.signInWithApple(idToken: idToken, rawNonce: nonce, fullName: credential.fullName, email: credential.email)
                try await resolveProfileAndRoute(requestedRole: requestedRole, isSessionRestore: false, provider: "apple")
            } catch {
                errorMessage = userFacingMessage(for: error)
            }
        }
    }

    func signOut() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await authService.signOut()
            clearState()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func resolveProfileAndRoute(requestedRole: UserRole, isSessionRestore: Bool, provider: String? = nil) async throws {
        guard let firebaseUser = authService.authUser() else { throw NSError(domain: "StorePass", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Not authenticated."]) }

        self.requestedRole = requestedRole
        lastRequestedRoleRaw = requestedRole.rawValue

        let providerValue = provider ?? authProvider(for: firebaseUser)
        let profile = try await roleProfileRepository.ensureUserProfile(
            uid: firebaseUser.uid,
            name: firebaseUser.displayName ?? "User",
            email: firebaseUser.email,
            provider: providerValue
        )
        print("[Auth] ensured users/\(firebaseUser.uid) exists=true role=\(profile.role.rawValue) isActive=\(profile.isActive)")

        showManagerAccessRequired = false
        showEmployeeSetupRequired = false

        guard profile.isActive else {
            managerAccessMessage = "Your account is currently inactive. Contact an administrator to restore access."
            showManagerAccessRequired = true
            resolvedRole = nil
            currentUser = nil
            authState = .signedOut
            return
        }

        if requestedRole == .manager, profile.role != .manager {
            managerAccessMessage = "This account is not marked as manager in users/\(firebaseUser.uid). Please switch to Employee mode or ask an admin to grant manager access."
            showManagerAccessRequired = true
            resolvedRole = nil
            currentUser = nil
            authState = .signedOut
            return
        }

        syncState(with: appUser(from: profile), role: profile.role)

        if isSessionRestore {
            return
        }
    }

    func resolveProfileAndRoute(requestedRole: UserRole?, isSessionRestore: Bool) async throws {
        guard let firebaseUser = authService.authUser() else {
            clearState()
            return
        }

        guard let profile = try await roleProfileRepository.fetchUserProfile(uid: firebaseUser.uid) else {
            try await authService.signOut()
            clearState()
            return
        }

        let resolvedRequest: UserRole?
        if let requestedRole {
            resolvedRequest = requestedRole
        } else {
            resolvedRequest = UserRole(rawValue: lastRequestedRoleRaw) ?? profile.role
        }

        guard let resolvedRequest else {
            try await authService.signOut()
            clearState()
            return
        }

        try await resolveProfileAndRoute(requestedRole: resolvedRequest, isSessionRestore: isSessionRestore, provider: authProvider(for: firebaseUser))
    }

    private func syncState(with user: AppUser, role: UserRole) {
        currentUser = user
        authService.setCurrentUser(user)
        resolvedRole = role
        authState = .signedIn(userId: user.id)
    }

    private func clearState() {
        authState = .signedOut
        resolvedRole = nil
        currentUser = nil
        authService.setCurrentUser(nil)
        showManagerAccessRequired = false
        managerAccessMessage = "This account does not have manager access. Please switch to Employee mode or ask an admin to update your role."
        showEmployeeSetupRequired = false
    }

    private func appUser(from profile: UserAccessProfile) -> AppUser {
        AppUser(
            id: profile.id,
            name: profile.name,
            email: profile.email,
            role: profile.role,
            createdAt: profile.createdAt,
            lastLoginAt: profile.lastLoginAt,
            provider: profile.provider,
            assignedStoreIds: profile.assignedStoreIds,
            isActive: profile.isActive
        )
    }

    private func authProvider(for user: FirebaseAuth.User) -> String {
        let providerId = user.providerData
            .map(\.providerID)
            .first { $0 == "google.com" || $0 == "apple.com" }

        switch providerId {
        case "google.com":
            return "google"
        case "apple.com":
            return "apple"
        default:
            return "unknown"
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain,
           nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
            return "You don't have permission for this action."
        }

        if nsError.domain == AuthErrorDomain,
           nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
            return "For security, sign in again and retry this action."
        }

        return error.localizedDescription
    }
}
