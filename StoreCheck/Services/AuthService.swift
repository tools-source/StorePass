import Foundation

protocol AuthServiceProtocol {
    var currentUser: UserProfile? { get }
    func restoreSession() async
    func login(email: String, password: String, expectedRole: UserRole) async throws
    func logout() throws
}

@MainActor
final class AuthService: ObservableObject, AuthServiceProtocol {
    @Published private(set) var currentUser: UserProfile?

    private let authRepository: AuthRepositoryProtocol
    private let userRepository: UserRepositoryProtocol

    init(authRepository: AuthRepositoryProtocol, userRepository: UserRepositoryProtocol) {
        self.authRepository = authRepository
        self.userRepository = userRepository
    }

    func restoreSession() async {
        guard let uid = authRepository.currentUserId else { return }
        currentUser = try? await userRepository.fetchUser(id: uid)
    }

    func login(email: String, password: String, expectedRole: UserRole) async throws {
        let uid = try await authRepository.signIn(email: email, password: password)
        let profile = try await userRepository.fetchUser(id: uid)
        guard profile.isActive else { throw NSError(domain: "StoreCheck", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Account disabled."]) }
        guard profile.role == expectedRole else {
            throw NSError(domain: "StoreCheck", code: 1002, userInfo: [NSLocalizedDescriptionKey: "This account does not match selected role."])
        }
        currentUser = profile
    }

    func logout() throws {
        try authRepository.signOut()
        currentUser = nil
    }
}
