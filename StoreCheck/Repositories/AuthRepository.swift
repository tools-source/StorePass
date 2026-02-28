import FirebaseAuth
import Foundation

protocol AuthRepositoryProtocol {
    var currentUserId: String? { get }
    func signIn(email: String, password: String) async throws -> String
    func createUser(email: String, password: String) async throws -> String
    func signOut() throws
}

final class FirebaseAuthRepository: AuthRepositoryProtocol {
    private var auth: Auth {
        FirebaseBootstrap.assertConfigured(context: "FirebaseAuthRepository.auth")
        return Auth.auth()
    }

    var currentUserId: String? { auth.currentUser?.uid }

    func signIn(email: String, password: String) async throws -> String {
        _ = email
        _ = password
        throw NSError(domain: "StorePass", code: 4101, userInfo: [NSLocalizedDescriptionKey: "Email/password sign-in is disabled. Use Google or Apple sign-in."])
    }

    func createUser(email: String, password: String) async throws -> String {
        _ = email
        _ = password
        throw NSError(domain: "StorePass", code: 4102, userInfo: [NSLocalizedDescriptionKey: "Email/password account creation is disabled. Use Google or Apple sign-in."])
    }

    func signOut() throws {
        try auth.signOut()
    }
}
