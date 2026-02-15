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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = authService.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = authService.sha256(nonce)
    }

    func handleAppleSignInResult(_ result: Result<ASAuthorization, Error>) {
        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                let credential = try extractAppleCredential(from: result)
                guard let nonce = currentNonce else {
                    throw NSError(domain: "StoreCheck", code: 3000, userInfo: [NSLocalizedDescriptionKey: "Invalid sign-in state. Please try again."])
                }
                guard let identityToken = credential.identityToken,
                      let idTokenString = String(data: identityToken, encoding: .utf8) else {
                    throw NSError(domain: "StoreCheck", code: 3001, userInfo: [NSLocalizedDescriptionKey: "Unable to read Apple identity token."])
                }

                try await authService.signInWithApple(
                    idToken: idTokenString,
                    rawNonce: nonce,
                    fullName: credential.fullName,
                    email: credential.email
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func extractAppleCredential(from result: Result<ASAuthorization, Error>) throws -> ASAuthorizationAppleIDCredential {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw NSError(domain: "StoreCheck", code: 3002, userInfo: [NSLocalizedDescriptionKey: "Invalid Apple credential."])
            }
            return credential
        case .failure(let error):
            throw error
        }
    }
}
