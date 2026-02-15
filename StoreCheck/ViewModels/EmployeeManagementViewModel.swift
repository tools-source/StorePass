import Foundation

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    @Published var employees: [UserProfile] = []
    @Published var errorMessage: String?

    private let userRepository: UserRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol

    init(userRepository: UserRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        self.userRepository = userRepository
        self.authRepository = authRepository
    }

    func load() async {
        do {
            employees = try await userRepository.fetchEmployees()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createEmployee(name: String, email: String, password: String, assignedStores: [String]) async {
        do {
            let uid = try await authRepository.createUser(email: email, password: password)
            let profile = UserProfile(
                id: uid,
                name: name,
                email: email,
                role: .employee,
                createdAt: Date(),
                lastLoginAt: Date(),
                provider: "password",
                assignedStoreIds: assignedStores,
                isActive: true
            )
            try await userRepository.upsertUser(profile)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setActive(_ employee: UserProfile, isActive: Bool) async {
        do {
            var copy = employee
            copy.isActive = isActive
            try await userRepository.upsertUser(copy)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
