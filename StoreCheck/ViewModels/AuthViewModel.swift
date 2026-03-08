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
    @Published private(set) var isCloudKitDegradedMode = false

    @AppStorage("lastRequestedRole") private var lastRequestedRoleRaw: String = ""

    private let authService: AuthServiceProtocol
    private let roleProfileRepository: RoleProfileRepositoryProtocol

    init(authService: AuthServiceProtocol, roleProfileRepository: RoleProfileRepositoryProtocol) {
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

    #if DEBUG
    func signInForDebug(role: UserRole) async {
        AppLog.info("AuthViewModel.signInForDebug started role=\(role.rawValue)")
        isLoading = true
        isRoleResolutionLoading = true
        errorMessage = nil
        signInNoticeMessage = nil
        defer {
            isLoading = false
            isRoleResolutionLoading = false
        }

        do {
            let seedEmail = role == .manager ? "manager.ui@test.storepass" : "employee.ui@test.storepass"
            let seedName = role == .manager ? "UI Manager" : "UI Employee"
            let result = try await authService.signInManuallyAsEmployee(name: seedName, email: seedEmail)
            lastRequestedRoleRaw = role.rawValue
            requestedRole = role
            try await resolveProfileAndRoute(identity: result.identity, requestedRole: role)
        } catch {
            logAuthError(error, context: "signInForDebug")
            errorMessage = userFacingMessage(for: error)
        }
    }
    #endif


    func signUpEmployee(name: String, email: String, password: String) async {
        AppLog.info("AuthViewModel.signUpEmployee started")
        isLoading = true
        isRoleResolutionLoading = true
        errorMessage = nil
        signInNoticeMessage = nil
        defer {
            isLoading = false
            isRoleResolutionLoading = false
        }

        do {
            let result = try await authService.signUpEmployee(name: name, email: email, password: password)
            lastRequestedRoleRaw = UserRole.employee.rawValue
            requestedRole = .employee
            try await resolveProfileAndRoute(identity: result.identity, requestedRole: .employee)
        } catch {
            logAuthError(error, context: "signUpEmployee")
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signInEmployee(email: String, password: String) async {
        AppLog.info("AuthViewModel.signInEmployee started")
        isLoading = true
        isRoleResolutionLoading = true
        errorMessage = nil
        signInNoticeMessage = nil
        defer {
            isLoading = false
            isRoleResolutionLoading = false
        }

        do {
            let result = try await authService.signInEmployee(email: email, password: password)
            lastRequestedRoleRaw = UserRole.employee.rawValue
            requestedRole = .employee

            do {
                if let profile = try await roleProfileRepository.fetchUserProfile(uid: result.identity.userId),
                   profile.role != .employee {
                    throw CloudKitClientError.invalidData("This account is not configured as an employee.")
                }
            } catch {
                guard shouldAllowDegradedMode(for: error) else {
                    throw error
                }
                AppLog.warning(
                    "Employee profile pre-check skipped due CloudKit identity mismatch for user=\(AppLog.redactIdentifier(result.identity.userId))"
                )
            }

            try await resolveProfileAndRoute(identity: result.identity, requestedRole: .employee)
        } catch {
            logAuthError(error, context: "signInEmployee")
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
        let status: RoleBootstrapStatus
        do {
            status = try await roleProfileRepository.ensureUserProfile(
                uid: identity.userId,
                name: identity.fullName,
                email: identity.email,
                provider: identity.provider,
                requestedRole: requestedRole
            )
        } catch {
            if shouldAllowDegradedMode(for: error),
               let degradedUser = makeDegradedModeUser(identity: identity, requestedRole: requestedRole) {
                AppLog.warning(
                    "CloudKit identity rejected; entering degraded login mode for user=\(AppLog.redactIdentifier(identity.userId))"
                )
                signInNoticeMessage = "Signed in with local fallback mode. Cloud sync is unavailable until CloudKit container setup is fixed."
                syncState(with: degradedUser, role: degradedUser.role, degradedMode: true)
                return
            }
            throw error
        }

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
        syncState(with: toAppUser(profile), role: profile.role, degradedMode: false)
    }

    private func syncState(with user: AppUser, role: UserRole, degradedMode: Bool) {
        currentUser = user
        authService.setCurrentUser(user)
        resolvedRole = role
        isCloudKitDegradedMode = degradedMode
        authState = .signedIn(userId: user.id)
        showManagerAccessRequired = false
    }

    private func clearState() {
        AppLog.info("AuthViewModel.clearState invoked")
        authState = .signedOut
        resolvedRole = nil
        currentUser = nil
        authService.setCurrentUser(nil)
        isCloudKitDegradedMode = false
        showManagerAccessRequired = false
        signInNoticeMessage = nil
    }

    private func shouldAllowDegradedMode(for error: Error) -> Bool {
        guard let cloudError = error as? CloudKitClientError,
              case .invalidData(let message) = cloudError else {
            return false
        }
        return message.localizedCaseInsensitiveContains("invalid bundle id for container")
    }

    private func makeDegradedModeUser(identity: AuthIdentity, requestedRole: UserRole?) -> AppUser? {
        let role = requestedRole ?? .employee
        let normalizedName = identity.fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackFromEmail = identity.email?
            .split(separator: "@")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let name = (normalizedName?.isEmpty == false ? normalizedName : nil)
            ?? (fallbackFromEmail?.isEmpty == false ? fallbackFromEmail : nil)
            ?? "StorePass User"

        return AppUser(
            id: identity.userId,
            name: name,
            email: identity.email,
            role: role,
            createdAt: Date(),
            lastLoginAt: Date(),
            provider: identity.provider,
            assignedStoreIds: [],
            isActive: true
        )
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
