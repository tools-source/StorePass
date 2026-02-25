import FirebaseAuth
import Foundation

protocol AuthRepositoryProtocol {
    var currentUserId: String? { get }
    func signOut() throws
}

final class FirebaseAuthRepository: AuthRepositoryProtocol {
    private var auth: Auth {
        FirebaseBootstrap.assertConfigured(context: "FirebaseAuthRepository.auth")
        return Auth.auth()
    }

    var currentUserId: String? { auth.currentUser?.uid }


    func signOut() throws {
        try auth.signOut()
    }
}
