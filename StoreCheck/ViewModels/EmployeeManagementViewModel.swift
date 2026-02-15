import Foundation

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var employees: [EmployeeSummary] = []
    @Published var selectedStoreId: String = "all"
    @Published var employeeError: String?
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
            employeeError = "Unable to resolve current manager session."
            print("[Employees] Session error: Unable to resolve current manager session.")
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            // 1) Fetch stores owned by this manager (safe query)
            let fetchedStores = try await employeeRepository.fetchManagerStores(managerId: managerId)
            stores = fetchedStores

            // Keep selectedStoreId valid
            if selectedStoreId != "all" && !fetchedStores.contains(where: { $0.id == selectedStoreId }) {
                selectedStoreId = "all"
            }

            // 2) Fetch employees using a 2-step approach (members -> users) to avoid composite indexes
            // IMPORTANT:
            // Your repository must implement this method using:
            // - query storeMembers/{storeId}/members (no orderBy)
            // - then fetch users/{uid} in chunks of 10 using documentID IN queries
            // - then sort locally
            employees = try await employeeRepository.fetchEmployeesForManagerStores(managerStores: fetchedStores)

            employeeError = nil
        } catch {
            employeeError = error.localizedDescription
            print("[Employees] Error: \(error.localizedDescription)")
        }
    }

    func removeFromStore(employeeId: String, storeId: String) async {
        do {
            try await employeeRepository.removeEmployeeFromStore(storeId: storeId, employeeId: employeeId)
            await load()
        } catch {
            employeeError = error.localizedDescription
            print("[Employees] Error: \(error.localizedDescription)")
        }
    }

    func removeFromAll(employeeId: String) async {
        guard let managerId = authRepository.currentUserId else { return }
        do {
            try await employeeRepository.removeEmployeeFromAllManagerStores(employeeId: employeeId, managerId: managerId)
            await load()
        } catch {
            employeeError = error.localizedDescription
            print("[Employees] Error: \(error.localizedDescription)")
        }
    }

    func updateStores(employeeId: String, storeIds: [String]) async {
        do {
            try await employeeRepository.setEmployeeStoresForManager(employeeId: employeeId, storeIds: storeIds)
            await load()
        } catch {
            employeeError = error.localizedDescription
            print("[Employees] Error: \(error.localizedDescription)")
        }
    }

    func setActive(employeeId: String, isActive: Bool) async {
        do {
            try await employeeRepository.setEmployeeActive(employeeId: employeeId, isActive: isActive)
            await load()
        } catch {
            employeeError = error.localizedDescription
            print("[Employees] Error: \(error.localizedDescription)")
        }
    }
}

/*
 REQUIRED REPOSITORY CHANGE

 Update your EmployeeManagementRepositoryProtocol to include:

 func fetchEmployeesForManagerStores(managerStores: [Store]) async throws -> [EmployeeSummary]

 And stop using:
 func fetchEmployeesForManager(managerId: String) async throws -> [EmployeeSummary]

 Because the managerId-based query often becomes a composite-index query.
 The store-based 2-step approach avoids indexes reliably.
*/
