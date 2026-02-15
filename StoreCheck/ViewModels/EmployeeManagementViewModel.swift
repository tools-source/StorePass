import Foundation

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var employees: [EmployeeSummary] = []
    @Published var selectedStoreId: String = "all"
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let employeeRepository: EmployeeManagementRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol

    init(employeeRepository: EmployeeManagementRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        self.employeeRepository = employeeRepository
        self.authRepository = authRepository
    }

    var filteredEmployees: [EmployeeSummary] {
        guard selectedStoreId != "all" else { return employees }
        return employees.filter { $0.storeIds.contains(selectedStoreId) }
    }

    func load() async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            stores = try await employeeRepository.fetchManagerStores(managerId: managerId)
            employees = try await employeeRepository.fetchEmployeesForManager(managerId: managerId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFromStore(employeeId: String, storeId: String) async {
        do {
            try await employeeRepository.removeEmployeeFromStore(storeId: storeId, employeeId: employeeId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeFromAll(employeeId: String) async {
        guard let managerId = authRepository.currentUserId else { return }
        do {
            try await employeeRepository.removeEmployeeFromAllManagerStores(employeeId: employeeId, managerId: managerId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateStores(employeeId: String, storeIds: [String]) async {
        do {
            try await employeeRepository.setEmployeeStoresForManager(employeeId: employeeId, storeIds: storeIds)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setActive(employeeId: String, isActive: Bool) async {
        do {
            try await employeeRepository.setEmployeeActive(employeeId: employeeId, isActive: isActive)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
