import Foundation

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    @Published var employees: [UserProfile] = []

    private let userRepository: UserRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol

    init(userRepository: UserRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        self.userRepository = userRepository
        self.authRepository = authRepository
    }

    func load() async {
        employees = (try? await userRepository.fetchEmployees()) ?? []
    }

    func createEmployee(name: String, email: String, password: String, assignedStores: [String]) async {
        do {
            let uid = try await authRepository.createUser(email: email, password: password)
            let profile = UserProfile(id: uid, name: name, email: email, role: .employee, assignedStoreIds: assignedStores, isActive: true, createdAt: Date())
            try await userRepository.upsertUser(profile)
            await load()
        } catch {
            print(error.localizedDescription)
        }
    }

    func setActive(_ employee: UserProfile, isActive: Bool) async {
        var updated = employee
        updated.isActive = isActive
        try? await userRepository.upsertUser(updated)
        await load()
    }
}
