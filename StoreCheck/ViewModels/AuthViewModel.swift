import AuthenticationServices
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
    @Published var signInNoticeMessage: String?
    @Published var showManagerAccessRequired = false
    @Published var managerAccessMessage = "This account does not have manager access."
    @Published private(set) var isRoleResolutionLoading = false
    @Published private(set) var currentUser: AppUser?

    @AppStorage("lastRequestedRole") private var lastRequestedRoleRaw: String = ""

    private let authService: AuthService
    private let roleProfileRepository: RoleProfileRepositoryProtocol

    init(authService: AuthService, roleProfileRepository: RoleProfileRepositoryProtocol) {
        self.authService = authService
        self.roleProfileRepository = roleProfileRepository
        self.requestedRole = UserRole(rawValue: lastRequestedRoleRaw)
    }

    func restoreSession(forceSignOutOnLaunch: Bool = false) async {
        AppLog.info("AuthViewModel.restoreSession started (forceSignOutOnLaunch=\(forceSignOutOnLaunch))")
        isLoading = true
        isRoleResolutionLoading = true
        defer {
            isLoading = false
            isRoleResolutionLoading = false
        }

        await authService.restoreSession(forceSignOutOnLaunch: forceSignOutOnLaunch)

        guard let identity = authService.authUser() else {
            AppLog.info("AuthViewModel.restoreSession found no cached identity")
            clearState()
            return
        }

        do {
            AppLog.info("AuthViewModel.restoreSession resolving profile for user=\(AppLog.redactIdentifier(identity.userId))")
            try await resolveProfileAndRoute(identity: identity, requestedRole: UserRole(rawValue: lastRequestedRoleRaw))
        } catch {
            logAuthError(error, context: "restoreSession.resolveProfileAndRoute")
            clearState()
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signInWithApple(requestedRole: UserRole) async {
        AppLog.info("AuthViewModel.signInWithApple started (requestedRole=\(requestedRole.rawValue))")
        isLoading = true
        isRoleResolutionLoading = true
        errorMessage = nil
        signInNoticeMessage = nil
        defer {
            isLoading = false
            isRoleResolutionLoading = false
        }

        do {
            let result = try await authService.signInWithApple()
            lastRequestedRoleRaw = requestedRole.rawValue
            self.requestedRole = requestedRole
            AppLog.info("AuthViewModel.signInWithApple received identity user=\(AppLog.redactIdentifier(result.identity.userId))")
            try await resolveProfileAndRoute(identity: result.identity, requestedRole: requestedRole)
        } catch {
            logAuthError(error, context: "signInWithApple.async")
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signInWithApple(authorizationResult: Result<ASAuthorization, Error>, requestedRole: UserRole) async {
        AppLog.info("AuthViewModel.signInWithApple(buttonResult) started (requestedRole=\(requestedRole.rawValue))")
        isLoading = true
        isRoleResolutionLoading = true
        errorMessage = nil
        signInNoticeMessage = nil
        defer {
            isLoading = false
            isRoleResolutionLoading = false
        }

        do {
            let result = try authService.signInWithApple(authorizationResult: authorizationResult)
            lastRequestedRoleRaw = requestedRole.rawValue
            self.requestedRole = requestedRole
            AppLog.info("AuthViewModel.signInWithApple(buttonResult) received identity user=\(AppLog.redactIdentifier(result.identity.userId))")
            try await resolveProfileAndRoute(identity: result.identity, requestedRole: requestedRole)
        } catch {
            logAuthError(error, context: "signInWithApple.buttonResult")
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signInManuallyAsEmployee(name: String, email: String) async {
        AppLog.info("AuthViewModel.signInManuallyAsEmployee started")
        isLoading = true
        isRoleResolutionLoading = true
        errorMessage = nil
        signInNoticeMessage = nil
        defer {
            isLoading = false
            isRoleResolutionLoading = false
        }

        do {
            let result = try await authService.signInManuallyAsEmployee(name: name, email: email)
            lastRequestedRoleRaw = UserRole.employee.rawValue
            requestedRole = .employee
            AppLog.info("AuthViewModel.signInManuallyAsEmployee received identity user=\(AppLog.redactIdentifier(result.identity.userId))")
            try await resolveProfileAndRoute(identity: result.identity, requestedRole: .employee)
        } catch {
            logAuthError(error, context: "signInManuallyAsEmployee")
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signOut() async {
        AppLog.info("AuthViewModel.signOut started")
        isLoading = true
        defer { isLoading = false }

        do {
            try await authService.signOut()
            clearState()
        } catch {
            logAuthError(error, context: "signOut")
            errorMessage = userFacingMessage(for: error)
        }
    }

    func updateDisplayName(_ newName: String) async throws {
        guard let user = currentUser else {
            throw CloudKitClientError.signedOut
        }

        let updated = try await roleProfileRepository.updateDisplayName(uid: user.id, name: newName)
        let appUser = toAppUser(updated)
        currentUser = appUser
        authService.setCurrentUser(appUser)
    }

    func deleteCurrentAccount() async throws {
        guard let user = currentUser else {
            throw CloudKitClientError.signedOut
        }

        try await roleProfileRepository.softDeleteAccount(uid: user.id, role: user.role)
        try await authService.deleteAuthAccount()
        clearState()
    }

    private func resolveProfileAndRoute(identity: AuthIdentity, requestedRole: UserRole?) async throws {
        AppLog.info(
            "Resolving CloudKit profile for user=\(AppLog.redactIdentifier(identity.userId)) requestedRole=\(requestedRole?.rawValue ?? "nil")"
        )
        let status = try await roleProfileRepository.ensureUserProfile(
            uid: identity.userId,
            name: identity.fullName,
            email: identity.email,
            provider: identity.provider,
            requestedRole: requestedRole
        )

        guard case .resolved(let profile) = status else {
            AppLog.warning("Profile resolution returned setupRequired for user=\(AppLog.redactIdentifier(identity.userId))")
            authState = .signedOut
            resolvedRole = nil
            currentUser = nil
            authService.setCurrentUser(nil)
            signInNoticeMessage = "Choose Manager or Employee to finish account setup."
            return
        }

        guard profile.isActive else {
            AppLog.warning("Resolved profile is inactive for user=\(AppLog.redactIdentifier(profile.id))")
            clearState()
            managerAccessMessage = "Your account is inactive. Contact your manager."
            showManagerAccessRequired = true
            return
        }

        if requestedRole == .manager && profile.role != .manager {
            AppLog.warning("Manager access denied for user=\(AppLog.redactIdentifier(profile.id)) resolvedRole=\(profile.role.rawValue)")
            try await authService.signOut()
            clearState()
            managerAccessMessage = "This account is not configured as a manager."
            showManagerAccessRequired = true
            return
        }

        AppLog.info("Profile resolved successfully for user=\(AppLog.redactIdentifier(profile.id)) role=\(profile.role.rawValue)")
        syncState(with: toAppUser(profile), role: profile.role)
    }

    private func syncState(with user: AppUser, role: UserRole) {
        currentUser = user
        authService.setCurrentUser(user)
        resolvedRole = role
        authState = .signedIn(userId: user.id)
        showManagerAccessRequired = false
    }

    private func clearState() {
        AppLog.info("AuthViewModel.clearState invoked")
        authState = .signedOut
        resolvedRole = nil
        currentUser = nil
        authService.setCurrentUser(nil)
        showManagerAccessRequired = false
        signInNoticeMessage = nil
    }

    private func toAppUser(_ profile: UserAccessProfile) -> AppUser {
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

    private func userFacingMessage(for error: Error) -> String {
        if let cloudError = error as? CloudKitClientError {
            return cloudError.localizedDescription
        }

        let nsError = error as NSError
        if nsError.domain == ASAuthorizationError.errorDomain {
            if nsError.code == ASAuthorizationError.canceled.rawValue {
                return "Apple sign-in was canceled."
            }
            return "Apple sign-in failed. Please try again."
        }

        return error.localizedDescription
    }

    private func logAuthError(_ error: Error, context: String) {
        let nsError = error as NSError
        let base = "Auth failure [\(context)] domain=\(nsError.domain) code=\(nsError.code)"
        if let ckError = error as? CloudKitClientError {
            AppLog.error("\(base) cloudClientError=\(String(describing: ckError)) message=\(AppLog.sanitize(ckError.localizedDescription))")
            return
        }
        AppLog.error("\(base) message=\(AppLog.sanitize(error.localizedDescription))", error: error)
    }
}
