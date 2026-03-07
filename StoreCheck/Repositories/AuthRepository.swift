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
            userInfo: [NSLocalizedDescriptionKey: "Use the login screen. Managers sign in with Apple, and employees can use Apple or quick email access."]
        )
    }

    func createUser(email: String, password: String) async throws -> String {
        _ = email
        _ = password
        throw NSError(
            domain: "StorePass",
            code: 4102,
            userInfo: [NSLocalizedDescriptionKey: "Accounts are created from the app login flow. Managers use Apple, and employees can use Apple or quick email access."]
        )
    }

    func signOut() throws {
        Task { [weak authService] in
            try? await authService?.signOut()
        }
    }
}
