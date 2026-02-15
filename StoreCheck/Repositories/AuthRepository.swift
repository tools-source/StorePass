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
        let result = try await auth.signIn(withEmail: email, password: password)
        return result.user.uid
    }

    func createUser(email: String, password: String) async throws -> String {
        let result = try await auth.createUser(withEmail: email, password: password)
        return result.user.uid
    }

    func signOut() throws {
        try auth.signOut()
    }
}
