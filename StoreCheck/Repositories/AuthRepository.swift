import FirebaseAuth
import Foundation

protocol AuthRepositoryProtocol {
    var currentUserId: String? { get }
    func signIn(email: String, password: String) async throws -> String
    func createUser(email: String, password: String) async throws -> String
    func signOut() throws
}

final class FirebaseAuthRepository: AuthRepositoryProtocol {
    var currentUserId: String? { Auth.auth().currentUser?.uid }

    func signIn(email: String, password: String) async throws -> String {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        return result.user.uid
    }

    func createUser(email: String, password: String) async throws -> String {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        return result.user.uid
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }
}
