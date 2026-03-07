import Foundation

@MainActor
protocol AuthRepositoryProtocol {
    var currentUserId: String? { get }
    func signIn(email: String, password: String) async throws -> String
    func createUser(email: String, password: String) async throws -> String
    func signOut() throws
}

@MainActor
final class CloudKitAuthRepository: AuthRepositoryProtocol {
    private weak var authService: AuthService?

    init(authService: AuthService) {
        self.authService = authService
    }

    var currentUserId: String? {
        authService?.currentIdentity?.userId
    }

    func signIn(email: String, password: String) async throws -> String {
        _ = email
        _ = password
        throw NSError(
            domain: "StorePass",
            code: 4101,
            userInfo: [NSLocalizedDescriptionKey: "Email/password sign-in is disabled. Use Sign in with Apple."]
        )
    }

    func createUser(email: String, password: String) async throws -> String {
        _ = email
        _ = password
        throw NSError(
            domain: "StorePass",
            code: 4102,
            userInfo: [NSLocalizedDescriptionKey: "Email/password account creation is disabled. Use Sign in with Apple."]
        )
    }

    func signOut() throws {
        Task { [weak authService] in
            try? await authService?.signOut()
        }
    }
}
