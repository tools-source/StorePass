import Foundation
import FirebaseFirestore
import FirebaseFunctions

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
    @Published private(set) var pendingStoreSelection: PendingStoreSelection?

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

    struct StoreRemovalTarget: Identifiable, Hashable {
        let storeId: String
        let storeName: String

        var id: String { storeId }
    }

    struct PendingStoreSelection {
        let employeeId: String
        let employeeName: String
        let targets: [StoreRemovalTarget]
    }

    var removalConfirmationMessage: String {
        guard let pendingRemoval else { return "" }
        return "Remove this employee from \(pendingRemoval.storeName)?"
    }

    func prepareRemoval(for employee: EmployeeSummary) {
        print("[UI][RemoveEmployee] swipeTriggered selectedFilterStoreId=\(selectedStoreId) employeeId=\(employee.id)")

        let targets = removalTargets(for: employee)
        print("[UI][RemoveEmployee] targetStoreIds=\(targets.map(\.storeId)) employeeId=\(employee.id)")

        if selectedStoreId == Self.allStoresFilter {
            guard !targets.isEmpty else {
                employeeError = "This employee is not assigned to a store."
                return
            }

            if targets.count == 1, let target = targets.first {
                pendingRemoval = PendingRemoval(employeeId: employee.id, employeeName: employee.name, storeId: target.storeId, storeName: target.storeName)
            } else {
                pendingStoreSelection = PendingStoreSelection(employeeId: employee.id, employeeName: employee.name, targets: targets)
            }
            return
        }

        guard let target = targets.first(where: { $0.storeId == selectedStoreId }) else {
            employeeError = "Select a store before removing this employee."
            return
        }

        pendingRemoval = PendingRemoval(employeeId: employee.id, employeeName: employee.name, storeId: target.storeId, storeName: target.storeName)
    }

    func cancelPendingRemoval() {
        pendingRemoval = nil
    }

    func cancelPendingStoreSelection() {
        pendingStoreSelection = nil
    }

    func confirmRemovalFromSelection(target: StoreRemovalTarget) {
        guard let selection = pendingStoreSelection else { return }
        pendingRemoval = PendingRemoval(employeeId: selection.employeeId, employeeName: selection.employeeName, storeId: target.storeId, storeName: target.storeName)
        pendingStoreSelection = nil
    }

    func executePendingRemoval() async {
        guard let pendingRemoval else { return }
        print("[UI][RemoveEmployee] tapped storeId=\(pendingRemoval.storeId) employeeId=\(pendingRemoval.employeeId)")
        await removeFromStore(employeeId: pendingRemoval.employeeId, storeId: pendingRemoval.storeId, storeName: pendingRemoval.storeName)
        cancelPendingRemoval()
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

    func removeFromStore(employeeId: String, storeId: String, storeName: String? = nil) async {
        guard !storeId.isEmpty else {
            employeeError = "Select a store first."
            return
        }
        do {
            print("[VM][RemoveEmployee] start storeId=\(storeId) employeeId=\(employeeId)")
            try await employeeRepository.removeEmployeeFromStore(storeId: storeId, employeeId: employeeId)
            print("[VM][RemoveEmployee] success storeId=\(storeId) employeeId=\(employeeId)")
            successMessage = "Removed from \(storeName ?? "store")."
            await load()
        } catch {
            print("[VM][RemoveEmployee] FAILED error=\(error)")
            logFunctionsErrorIfPresent(error)
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

    private func logFunctionsErrorIfPresent(_ error: Error) {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain else { return }

        let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
        let details = nsError.userInfo[FunctionsErrorDetailsKey].map { String(describing: $0) } ?? "nil"
        print("[VM][RemoveEmployee] FAILED domain=\(nsError.domain) code=\(nsError.code) message=\(message) details=\(details)")
    }

    private func removalTargets(for employee: EmployeeSummary) -> [StoreRemovalTarget] {
        let fallbackStoreNames = Dictionary(uniqueKeysWithValues: zip(employee.storeIds, employee.storeNames))

        return employee.storeIds.map { storeId in
            let storeName = stores.first(where: { $0.id == storeId })?.name
                ?? fallbackStoreNames[storeId]
                ?? storeId
            return StoreRemovalTarget(storeId: storeId, storeName: storeName)
        }
        .sorted { $0.storeName.localizedCaseInsensitiveCompare($1.storeName) == .orderedAscending }
    }
}
