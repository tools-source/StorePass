import Foundation
import FirebaseFirestore

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    static let allStoresFilter = "all"

    @Published var stores: [Store] = []
    @Published var employees: [EmployeeSummary] = []
    @Published var selectedStoreId: String = EmployeeManagementViewModel.allStoresFilter
    @Published var employeeError: String?
    @Published var bannerMessage: String?
    @Published var isLoading = false

    private let employeeRepository: EmployeeManagementRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol

    init(employeeRepository: EmployeeManagementRepositoryProtocol, authRepository: AuthRepositoryProtocol) {
        self.employeeRepository = employeeRepository
        self.authRepository = authRepository
    }

    var filteredEmployees: [EmployeeSummary] {
        guard selectedStoreId != Self.allStoresFilter else { return employees }
        return employees.filter { $0.storeIds.contains(selectedStoreId) }
    }

    func storeSummary(for employee: EmployeeSummary) -> String {
        guard !employee.storeNames.isEmpty else {
            return "Stores: None"
        }

        return "Stores: \(employee.storeNames.joined(separator: ", "))"
    }

    func load() async {
        guard let managerId = authRepository.currentUserId else {
            employeeError = "Unable to resolve current manager session."
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
        }
    }

    func removeFromStore(employeeId: String, storeId: String) async {
        do {
            try await employeeRepository.removeEmployeeFromStore(storeId: storeId, employeeId: employeeId)
            await load()
        } catch {
            if isFirestorePermissionDenied(error) {
                bannerMessage = "Permission denied. Check Firestore rules."
                FirestorePermissionLogger.log(operation: "removeEmployeeFromStore", path: "stores/\(storeId)/members/\(employeeId)", error: error)
            }
            employeeError = error.localizedDescription
        }
    }

    func removeFromAll(employeeId: String) async {
        guard let managerId = authRepository.currentUserId else { return }

        do {
            try await employeeRepository.removeEmployeeFromAllManagerStores(employeeId: employeeId, managerId: managerId)
            await load()
        } catch {
            if isFirestorePermissionDenied(error) {
                bannerMessage = "Permission denied. Check Firestore rules."
                FirestorePermissionLogger.log(operation: "removeEmployeeFromAllManagerStores", path: "managerStores/\(managerId)/* + stores/*/members/\(employeeId)", error: error)
            }
            employeeError = error.localizedDescription
        }
    }

    func setActive(employeeId: String, isActive: Bool) async {
        do {
            try await employeeRepository.setEmployeeActive(employeeId: employeeId, isActive: isActive)
            await load()
        } catch {
            if isFirestorePermissionDenied(error) {
                bannerMessage = "Permission denied. Check Firestore rules."
                FirestorePermissionLogger.log(operation: "setEmployeeActive", path: "users/\(employeeId) + stores/*/members/\(employeeId)", error: error)
            }
            employeeError = error.localizedDescription
        }
    }

    private func isFirestorePermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain && nsError.code == 7
    }
}
