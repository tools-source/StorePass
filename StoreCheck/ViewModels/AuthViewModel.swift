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
            try await resolveProfileAndRoute(requestedRole: requestedRole, isSessionRestore: false)
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
                try await resolveProfileAndRoute(requestedRole: requestedRole, isSessionRestore: false)
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

    func resolveProfileAndRoute(requestedRole: UserRole, isSessionRestore: Bool) async throws {
        guard let firebaseUser = authService.authUser() else { throw NSError(domain: "StorePass", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Not authenticated."]) }

        self.requestedRole = requestedRole
        lastRequestedRoleRaw = requestedRole.rawValue

        let managerProfile = try await roleProfileRepository.fetchManagerProfile(uid: firebaseUser.uid)
        var employeeProfile = try await roleProfileRepository.fetchEmployeeProfile(uid: firebaseUser.uid)

        showManagerAccessRequired = false
        showEmployeeSetupRequired = false

        switch requestedRole {
        case .manager:
            guard let managerProfile else {
                showManagerAccessRequired = true
                resolvedRole = nil
                currentUser = nil
                authState = .signedOut
                return
            }
            syncState(with: appUser(from: managerProfile, fallbackEmail: firebaseUser.email), role: .manager)

        case .employee:
            if employeeProfile == nil {
                try await roleProfileRepository.upsertEmployeeProfile(
                    uid: firebaseUser.uid,
                    name: firebaseUser.displayName ?? "StorePass User",
                    email: firebaseUser.email
                )
                employeeProfile = try await roleProfileRepository.fetchEmployeeProfile(uid: firebaseUser.uid)
            }

            guard let employeeProfile else {
                showEmployeeSetupRequired = true
                return
            }
            syncState(with: appUser(from: employeeProfile, fallbackEmail: firebaseUser.email), role: .employee)
        }

        if isSessionRestore {
            return
        }
    }

    func resolveProfileAndRoute(requestedRole: UserRole?, isSessionRestore: Bool) async throws {
        guard let firebaseUser = authService.authUser() else {
            clearState()
            return
        }

        let managerProfile = try await roleProfileRepository.fetchManagerProfile(uid: firebaseUser.uid)
        let employeeProfile = try await roleProfileRepository.fetchEmployeeProfile(uid: firebaseUser.uid)

        let resolvedRequest: UserRole?
        if let requestedRole {
            resolvedRequest = requestedRole
        } else if managerProfile != nil, employeeProfile != nil {
            resolvedRequest = UserRole(rawValue: lastRequestedRoleRaw)
        } else if managerProfile != nil {
            resolvedRequest = .manager
        } else if employeeProfile != nil {
            resolvedRequest = .employee
        } else {
            resolvedRequest = nil
        }

        guard let resolvedRequest else {
            try await authService.signOut()
            clearState()
            return
        }

        try await resolveProfileAndRoute(requestedRole: resolvedRequest, isSessionRestore: isSessionRestore)
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
        showEmployeeSetupRequired = false
    }

    private func appUser(from manager: ManagerProfile, fallbackEmail: String?) -> AppUser {
        AppUser(
            id: manager.id,
            name: manager.name,
            email: manager.email ?? fallbackEmail,
            role: .manager,
            createdAt: manager.createdAt,
            lastLoginAt: manager.lastLoginAt,
            provider: "federated",
            assignedStoreIds: [],
            isActive: manager.isActive
        )
    }

    private func appUser(from employee: EmployeeProfile, fallbackEmail: String?) -> AppUser {
        AppUser(
            id: employee.id,
            name: employee.name,
            email: employee.email ?? fallbackEmail,
            role: .employee,
            createdAt: employee.createdAt,
            lastLoginAt: employee.lastLoginAt,
            provider: "federated",
            assignedStoreIds: employee.assignedStoreIds,
            isActive: employee.isActive
        )
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
