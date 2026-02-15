import AuthenticationServices
import Foundation

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let authService: AuthService
    private(set) var currentNonce: String?

    init(authService: AuthService) {
        self.authService = authService
    }

    func restoreSession() async {
        isLoading = true
        defer { isLoading = false }
        await authService.restoreSession()
    }

    func signInWithGoogle() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await authService.signInWithGoogle()
            try await authService.bootstrapManagerIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = authService.randomNonceString(length: 32)
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = authService.sha256(nonce)
    }

    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
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
                try await authService.bootstrapManagerIfNeeded()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
