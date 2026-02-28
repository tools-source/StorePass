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
    @Published var signInNoticeMessage: String?
    @Published var shouldShowAppleNamePrompt = false
    @Published var pendingNameUpdate = ""
    @Published var showManagerAccessRequired = false
    @Published var managerAccessMessage = "This account does not have manager access. Please switch to Employee mode or ask an admin to update your role."
    @Published var showEmployeeSetupRequired = false
    @Published private(set) var isRoleResolutionLoading = false
    @Published private(set) var currentUser: AppUser?

    @AppStorage("lastRequestedRole") private var lastRequestedRoleRaw: String = ""

    private let authService: AuthService
    private let roleProfileRepository: RoleProfileRepositoryProtocol
    private var isResolvingProfile = false

    init(authService: AuthService, roleProfileRepository: RoleProfileRepositoryProtocol) {
        self.authService = authService
        self.roleProfileRepository = roleProfileRepository
        self.requestedRole = UserRole(rawValue: lastRequestedRoleRaw)
    }

    func restoreSession(forceSignOutOnLaunch: Bool = false) async {
        isLoading = true
        isRoleResolutionLoading = true
        defer { isLoading = false }
        defer { isRoleResolutionLoading = false }

        await authService.restoreSession(forceSignOutOnLaunch: forceSignOutOnLaunch)

        if let firebaseUser = authService.authUser() {
            let providerIDs = firebaseUser.providerData.map(\.providerID)
            print("[AuthStartup] uid=\(firebaseUser.uid) providerIDs=\(providerIDs)")
        } else {
            print("[AuthStartup] uid=nil providerIDs=[]")
        }

        guard authService.authUser() != nil else {
            clearState()
            return
        }

        do {
            try await resolveProfileAndRoute(requestedRole: UserRole(rawValue: lastRequestedRoleRaw), isSessionRestore: true)
        } catch {
            showEmployeeSetupRequired = true
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signInWithGoogle(requestedRole: UserRole) async {
        guard !isResolvingProfile else { return }
        signInNoticeMessage = nil
        isLoading = true
        isRoleResolutionLoading = true
        defer { isLoading = false }
        defer { isRoleResolutionLoading = false }

        do {
            try await authService.signInWithGoogle()
            try await resolveProfileAndRoute(requestedRole: requestedRole, isSessionRestore: false, provider: "google")
        } catch {
            showEmployeeSetupRequired = true
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signInWithApple(requestedRole: UserRole) async {
        guard !isResolvingProfile else { return }
        signInNoticeMessage = nil
        isLoading = true
        isRoleResolutionLoading = true
        defer { isLoading = false }
        defer { isRoleResolutionLoading = false }

        do {
            let appleResult = try await authService.signInWithApple()
            let resolvedName = PersonNameComponentsFormatter().string(from: appleResult.fullName ?? PersonNameComponents()).trimmingCharacters(in: .whitespacesAndNewlines)
            try await resolveProfileAndRoute(
                requestedRole: requestedRole,
                isSessionRestore: false,
                provider: "apple",
                preferredName: resolvedName.isEmpty ? nil : resolvedName
            )
            evaluateAppleNamePromptAfterSignIn(appleFullName: resolvedName)
        } catch {
            showEmployeeSetupRequired = true
            errorMessage = userFacingMessage(for: error)
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

    func resolveProfileAndRoute(
        requestedRole: UserRole,
        isSessionRestore: Bool,
        provider: String? = nil,
        preferredName: String? = nil,
        preferredEmail: String? = nil
    ) async throws {
        guard let firebaseUser = authService.authUser() else { throw NSError(domain: "StorePass", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Not authenticated."]) }
        guard !isResolvingProfile else { return }
        isResolvingProfile = true
        defer { isResolvingProfile = false }

        self.requestedRole = requestedRole
        lastRequestedRoleRaw = requestedRole.rawValue
        logAuth("role_resolution_started", uid: firebaseUser.uid, requestedRole: requestedRole, details: ["isSessionRestore": isSessionRestore])

        let providerValue = provider ?? authProvider(for: firebaseUser)
        let resolvedName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = preferredEmail?.trimmingCharacters(in: .whitespacesAndNewlines)

        let status = try await roleProfileRepository.ensureUserProfile(
            uid: firebaseUser.uid,
            name: resolvedName?.isEmpty == false ? resolvedName : firebaseUser.displayName,
            email: resolvedEmail?.isEmpty == false ? resolvedEmail : firebaseUser.email,
            provider: providerValue,
            requestedRole: requestedRole
        )
        guard case .resolved(let profile) = status else {
            showEmployeeSetupRequired = true
            currentUser = nil
            resolvedRole = nil
            authState = .signedOut
            logAuth("role_resolution_setup_required", uid: firebaseUser.uid, requestedRole: requestedRole)
            logAuth("routing_decision", uid: firebaseUser.uid, requestedRole: requestedRole, details: ["decision": "setupRequired"])
            return
        }
        logAuth("role_resolution_loaded", uid: firebaseUser.uid, requestedRole: requestedRole, details: ["resolvedRole": profile.role.rawValue, "isActive": profile.isActive])
        do {
            let userDoc = try await Firestore.firestore().collection("users").document(firebaseUser.uid).getDocument()
            print("[AuthStartup] uid=\(firebaseUser.uid) resolvedRole=\(profile.role.rawValue) isActive=\(profile.isActive) userDocExists=\(userDoc.exists)")
        } catch {
            print("[AuthStartup] uid=\(firebaseUser.uid) resolvedRole=\(profile.role.rawValue) isActive=\(profile.isActive) userDocExists=unknown error=\(error.localizedDescription)")
        }

        showManagerAccessRequired = false
        showEmployeeSetupRequired = false

        guard profile.isActive else {
            managerAccessMessage = "Your account is currently inactive. Contact an administrator to restore access."
            showManagerAccessRequired = true
            resolvedRole = nil
            currentUser = nil
            authState = .signedOut
            logAuth("route_signed_out_inactive", uid: firebaseUser.uid, requestedRole: requestedRole, details: ["resolvedRole": profile.role.rawValue])
            return
        }

        if requestedRole == .manager, profile.role != .manager {
            await signOutToLogin(
                message: "This account is an \(profile.role.rawValue). Please use Employee mode.",
                uid: firebaseUser.uid,
                requestedRole: requestedRole,
                resolvedRole: profile.role.rawValue
            )
            return
        }

        syncState(with: appUser(from: profile), role: profile.role)
        logAuth("route_signed_in", uid: firebaseUser.uid, requestedRole: requestedRole, details: ["resolvedRole": profile.role.rawValue])
        logAuth("routing_decision", uid: firebaseUser.uid, requestedRole: requestedRole, details: ["decision": "resolved", "resolvedRole": profile.role.rawValue])

        if isSessionRestore {
            return
        }
    }

    func resolveProfileAndRoute(requestedRole: UserRole?, isSessionRestore: Bool) async throws {
        guard let firebaseUser = authService.authUser() else {
            clearState()
            return
        }

        let providerValue = authProvider(for: firebaseUser)

        let status = try await roleProfileRepository.ensureUserProfile(
            uid: firebaseUser.uid,
            name: firebaseUser.displayName,
            email: firebaseUser.email,
            provider: providerValue,
            requestedRole: requestedRole
        )

        guard case .resolved(let profile) = status else {
            showEmployeeSetupRequired = true
            authState = .signedOut
            resolvedRole = nil
            currentUser = nil
            authService.setCurrentUser(nil)
            logAuth("routing_decision", uid: firebaseUser.uid, requestedRole: requestedRole, details: ["decision": "setupRequired"])
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

        try await resolveProfileAndRoute(
            requestedRole: resolvedRequest,
            isSessionRestore: isSessionRestore,
            provider: authProvider(for: firebaseUser)
        )
    }

    func completeSetup(with role: UserRole) async {
        guard !isResolvingProfile else { return }
        await signInRecovery(with: role)
    }

    private func signInRecovery(with role: UserRole) async {
        isLoading = true
        isRoleResolutionLoading = true
        defer { isLoading = false }
        defer { isRoleResolutionLoading = false }

        do {
            try await resolveProfileAndRoute(requestedRole: role, isSessionRestore: false)
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
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
        isRoleResolutionLoading = false
    }

    private func signOutToLogin(message: String, uid: String, requestedRole: UserRole, resolvedRole: String) async {
        do {
            try await authService.signOut()
        } catch {
            logAuth("sign_out_failed", uid: uid, requestedRole: requestedRole, details: ["error": error.localizedDescription])
        }

        clearState()
        signInNoticeMessage = message
        logAuth("route_signed_out_non_manager", uid: uid, requestedRole: requestedRole, details: ["resolvedRole": resolvedRole])
    }

    private func logAuth(_ event: String, uid: String, requestedRole: UserRole?, details: [String: Any] = [:]) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let requestedRoleValue = requestedRole?.rawValue ?? "nil"
        let thread = Thread.isMainThread ? "main" : "background"
        print("[AuthLog] ts=\(timestamp) event=\(event) uid=\(uid) requestedRole=\(requestedRoleValue) thread=\(thread) details=\(details)")
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
            .first { $0 == "apple.com" || $0 == "google.com" }

        switch providerId {
        case "apple.com":
            return "apple"
        case "google.com":
            return "google"
        default:
            return "unknown"
        }
    }


    func saveAppleDisplayName() async {
        let trimmed = pendingNameUpdate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter your name."
            return
        }
        guard let firebaseUser = authService.authUser() else {
            errorMessage = "You must be signed in."
            return
        }

        do {
            try await Firestore.firestore().collection("users").document(firebaseUser.uid).setData([
                "name": trimmed,
                "updatedAt": FieldValue.serverTimestamp(),
                "provider": "apple"
            ], merge: true)

            if var existingUser = currentUser {
                existingUser.name = trimmed
                existingUser.provider = "apple"
                syncState(with: existingUser, role: existingUser.role)
            }

            pendingNameUpdate = trimmed
            shouldShowAppleNamePrompt = false
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    private func evaluateAppleNamePromptAfterSignIn(appleFullName: String?) {
        guard let firebaseUser = authService.authUser() else { return }
        let providerIds = Set(firebaseUser.providerData.map(\.providerID))
        guard providerIds.contains("apple.com") else { return }
        guard var user = currentUser else { return }

        let existingName = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppleName = appleFullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let emailPrefix = (user.email ?? firebaseUser.email ?? "")
            .split(separator: "@")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !existingName.isEmpty {
            pendingNameUpdate = existingName
        } else if !normalizedAppleName.isEmpty {
            pendingNameUpdate = normalizedAppleName
        } else {
            pendingNameUpdate = emailPrefix.isEmpty ? "StorePass User" : emailPrefix
        }

        shouldShowAppleNamePrompt = true
        user.provider = "apple"
        syncState(with: user, role: user.role)
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
