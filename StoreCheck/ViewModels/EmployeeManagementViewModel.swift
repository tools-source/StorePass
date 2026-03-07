import Foundation

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    static let allStoresFilter = "all"

    @Published var stores: [Store] = []
    @Published var employees: [EmployeeSummary] = []
    @Published var selectedStoreId: String = EmployeeManagementViewModel.allStoresFilter
    @Published var employeeError: String?
    @Published var successMessage: String?
    @Published var bannerMessage: String?
    @Published var isLoading = false
    @Published private(set) var pendingRemoval: PendingRemoval?

    private let employeeRepository: EmployeeManagementRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol

    init(employeeRepository: EmployeeManagementRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        self.employeeRepository = employeeRepository
        self.authRepository = authRepository
    }

    struct PendingRemoval {
        let employeeId: String
        let employeeName: String
        let storeId: String
        let storeName: String
    }

    var removalConfirmationMessage: String {
        guard let pendingRemoval else { return "" }
        return "Remove \(pendingRemoval.employeeName) from \(pendingRemoval.storeName)?"
    }

    var filteredEmployees: [EmployeeSummary] {
        guard selectedStoreId != Self.allStoresFilter else { return employees }
        return employees.filter { $0.storeIds.contains(selectedStoreId) }
    }

    func storeSummary(for employee: EmployeeSummary) -> String {
        guard !employee.storeNames.isEmpty else {
            return "No store memberships"
        }
        return employee.storeNames.joined(separator: ", ")
    }

    func load() async {
        guard let managerId = authRepository.currentUserId else {
            employeeError = "Unable to resolve manager session."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let fetchedStores = try await employeeRepository.fetchManagerStores(managerId: managerId)
            stores = fetchedStores

            if selectedStoreId != Self.allStoresFilter,
               !fetchedStores.contains(where: { $0.id == selectedStoreId }) {
                selectedStoreId = Self.allStoresFilter
            }

            employees = try await employeeRepository.fetchEmployeesForManagerStores(managerStores: fetchedStores)
            employeeError = nil
        } catch {
            employeeError = error.localizedDescription
            AppLog.error("Failed loading employees", error: error)
        }
    }

    func prepareRemoval(for employee: EmployeeSummary) {
        let targetStoreId: String

        if selectedStoreId == Self.allStoresFilter {
            guard let firstStore = employee.storeIds.first else {
                employeeError = "Employee has no active store membership."
                return
            }
            targetStoreId = firstStore
        } else {
            targetStoreId = selectedStoreId
        }

        guard let store = stores.first(where: { $0.id == targetStoreId }) else {
            employeeError = "Select a valid store before removing membership."
            return
        }

        pendingRemoval = PendingRemoval(
            employeeId: employee.id,
            employeeName: employee.name,
            storeId: store.id,
            storeName: store.name
        )
    }

    func cancelPendingRemoval() {
        pendingRemoval = nil
    }

    func executePendingRemoval() async {
        guard let pendingRemoval else { return }
        defer { self.pendingRemoval = nil }

        do {
            try await employeeRepository.removeEmployeeFromStore(
                storeId: pendingRemoval.storeId,
                employeeId: pendingRemoval.employeeId
            )
            successMessage = "Removed from \(pendingRemoval.storeName)."
            await load()
        } catch {
            employeeError = error.localizedDescription
            AppLog.error("Failed removing employee from store", error: error)
        }
    }

    func setActive(employeeId: String, isActive: Bool) async {
        do {
            try await employeeRepository.setEmployeeActive(employeeId: employeeId, isActive: isActive)
            await load()
        } catch {
            employeeError = error.localizedDescription
            AppLog.error("Failed updating employee active status", error: error)
        }
    }
}
