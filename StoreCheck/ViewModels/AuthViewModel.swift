import AuthenticationServices
import FirebaseFirestore
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    enum AuthState: Equatable {
        case signedOut
        case signedIn(userId: String)
    }

    @Published var authState: AuthState = .signedOut
    @Published var resolvedRole: UserRole?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var currentUser: AppUser?

    private let authService: AuthService
    private(set) var currentNonce: String?

    init(authService: AuthService) {
        self.authService = authService
    }

    func restoreSession(forceSignOutOnLaunch: Bool = false) async {
        #if DEBUG
        print("[AuthViewModel] restoreSession start")
        #endif
        isLoading = true
        defer { isLoading = false }

        await authService.restoreSession(forceSignOutOnLaunch: forceSignOutOnLaunch)

        guard authService.currentUser != nil else {
            #if DEBUG
            print("[AuthViewModel] restoreSession complete: no active session")
            #endif
            clearState()
            return
        }

        do {
            try await resolveRoleAfterSignIn(preferredRole: nil)
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func signInWithGoogle(preferredRole: UserRole? = nil) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await authService.signInWithGoogle()
            try await resolveRoleAfterSignIn(preferredRole: preferredRole)
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

    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>, preferredRole: UserRole? = nil) {
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
                try await resolveRoleAfterSignIn(preferredRole: preferredRole)
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

    private func resolveRoleAfterSignIn(preferredRole: UserRole?) async throws {
        let user = try await authService.refreshCurrentUserProfile()

        #if DEBUG
        print("[AuthViewModel] resolved role=\(user.role.rawValue) for uid=\(user.id)")
        #endif

        guard user.isActive else {
            #if DEBUG
            print("[AuthViewModel] Manager access denied: account inactive for uid \(user.id)")
            #endif
            errorMessage = "This account is inactive. Contact your administrator."
            try await authService.signOut()
            clearState()
            return
        }

        syncState(with: user)

        guard let preferredRole else { return }
        guard preferredRole != user.role else { return }

        if preferredRole == .manager && user.role == .employee {
            #if DEBUG
            print("[AuthViewModel] Manager access denied: role mismatch for uid \(user.id), role=\(user.role.rawValue)")
            #endif
            errorMessage = "This account is not a manager."
            try await authService.signOut()
            clearState()
        } else if preferredRole == .employee && user.role == .manager {
            errorMessage = "Manager account detected. Routing you to Manager tools."
        }
    }


    private func syncState(with user: AppUser) {
        #if DEBUG
        print("[AuthViewModel] syncState uid=\(user.id) role=\(user.role.rawValue)")
        #endif
        currentUser = user
        resolvedRole = user.role
        authState = .signedIn(userId: user.id)
    }

    private func clearState() {
        authState = .signedOut
        resolvedRole = nil
        currentUser = nil
    }

    private func userFacingMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain,
           nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
            return "You don't have permission for this action. If this is your first manager login, ask an admin to set users/{uid}.role to manager in Firestore."
        }

        return error.localizedDescription
    }
}
