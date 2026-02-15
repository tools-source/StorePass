import Foundation

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    @Published var employees: [EmployeeSummary] = []
    @Published var errorMessage: String?
    @Published var filterStoreId: String = ""
    @Published var isLoading = false

    private let employeeRepository: EmployeeManagementRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol

    init(employeeRepository: EmployeeManagementRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        self.employeeRepository = employeeRepository
        self.authRepository = authRepository
    }

    var filteredEmployees: [EmployeeSummary] {
        guard !filterStoreId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return employees
        }

        let storeId = filterStoreId.trimmingCharacters(in: .whitespacesAndNewlines)
        return employees.filter {
            $0.assignedStoreIds.contains(storeId) || $0.linkedStoreIds.contains(storeId)
        }
    }

    func load() async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            employees = try await employeeRepository.fetchEmployeesForManager(managerId: managerId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createEmployee(name: String, email: String, password: String, assignedStores: [String]) async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        do {
            try await employeeRepository.createEmployeeUnderManager(
                managerId: managerId,
                name: name,
                email: email,
                tempPassword: password,
                storeIds: assignedStores
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateStores(employeeId: String, storeIds: [String]) async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        do {
            try await employeeRepository.updateEmployeeStores(managerId: managerId, employeeId: employeeId, storeIds: storeIds)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setActive(employeeId: String, isActive: Bool) async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        do {
            try await employeeRepository.setEmployeeActive(managerId: managerId, employeeId: employeeId, isActive: isActive)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unlink(employeeId: String) async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        do {
            try await employeeRepository.unlinkEmployee(managerId: managerId, employeeId: employeeId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
