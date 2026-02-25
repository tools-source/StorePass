import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// What changed:
// - Hardened Firebase Functions error logging to avoid unavailable SDK constants.

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    static let allStoresFilter = "all"
    private let removeEmployeeFunctionName = "removeEmployeeFromStore"
    private let removeEmployeeFunctionRegion = "us-central1"

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

    func targetStoreIds(for employee: EmployeeSummary) -> [String] {
        let targets = removalTargets(for: employee)

        if selectedStoreId == Self.allStoresFilter {
            return targets.map(\.storeId)
        }

        return targets.filter { $0.storeId == selectedStoreId }.map(\.storeId)
    }

    func prepareRemoval(for employee: EmployeeSummary) {
        print("[UI][RemoveEmployee] swipe storeFilter=\(selectedStoreId) employeeId=\(employee.id)")

        let targets = removalTargets(for: employee)
        print("[RemoveEmployee] computeTargets filter=\(selectedStoreId) employeeStores=\(targets.map(\.storeId))")

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
        _ = await removeFromStore(employeeId: pendingRemoval.employeeId, storeId: pendingRemoval.storeId, storeName: pendingRemoval.storeName)
        cancelPendingRemoval()
    }

    func removeEmployee(employeeId: String, employeeName: String, targetStoreIds: [String]) async {
        guard !targetStoreIds.isEmpty else {
            employeeError = "Select a store before removing this employee."
            return
        }

        print("[VM][RemoveEmployee] start employeeId=\(employeeId) targetStoreIds=\(targetStoreIds)")

        var allSucceeded = true
        for storeId in targetStoreIds {
            let storeName = stores.first(where: { $0.id == storeId })?.name ?? storeId
            print("[VM][RemoveEmployee] callingFunction storeId=\(storeId) employeeId=\(employeeId)")
            let succeeded = await removeFromStore(employeeId: employeeId, storeId: storeId, storeName: storeName)
            allSucceeded = allSucceeded && succeeded
        }

        if allSucceeded {
            print("[VM][RemoveEmployee] success -> refreshing employees list")
            await load()
            successMessage = "Removed \(employeeName) from selected store memberships."
        }
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

    func removeFromStore(employeeId: String, storeId: String, storeName: String? = nil) async -> Bool {
        guard !storeId.isEmpty else {
            employeeError = "Select a store first."
            return false
        }
        do {
            await logRemovalContext(storeId: storeId, employeeId: employeeId)
            try await employeeRepository.removeEmployeeFromStore(storeId: storeId, employeeId: employeeId)
            print("[RemoveEmployee][OK] storeId=\(storeId) employeeId=\(employeeId) result=ok")
            employees = employees.compactMap { summary in
                guard summary.id == employeeId else { return summary }
                let remainingStoreIds = summary.storeIds.filter { $0 != storeId }
                if remainingStoreIds.isEmpty { return nil }
                let remainingStoreNames = summary.storeIds.enumerated().compactMap { index, id in
                    id == storeId ? nil : summary.storeNames[safe: index]
                }
                return EmployeeSummary(
                    id: summary.id,
                    name: summary.name,
                    email: summary.email,
                    storeIds: remainingStoreIds,
                    storeNames: remainingStoreNames,
                    userIsActive: summary.userIsActive,
                    hasInactiveMembership: summary.hasInactiveMembership
                )
            }
            successMessage = "Removed from \(storeName ?? "store")."
            return true
        } catch {
            print("[RemoveEmployee][FAIL] function=\(removeEmployeeFunctionName) region=\(removeEmployeeFunctionRegion) error=\(error)")
            logFunctionsErrorIfPresent(error)
            if isFirestorePermissionDenied(error) {
                bannerMessage = "Permission denied. Check Firestore rules."
                FirestorePermissionLogger.log(operation: "removeEmployeeFromStore", path: "stores/\(storeId)/members/\(employeeId)", error: error)
            }
            employeeError = error.localizedDescription
            return false
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

    private func logRemovalContext(storeId: String, employeeId: String) async {
        let uid = Auth.auth().currentUser?.uid ?? "nil"
        let providerIDs = Auth.auth().currentUser?.providerData.map(\.providerID) ?? []
        var role = "nil"
        var isActive = "nil"

        if uid != "nil" {
            do {
                let userDoc = try await Firestore.firestore().collection("users").document(uid).getDocument()
                role = (userDoc.data()?["role"] as? String) ?? "nil"
                if let active = userDoc.data()?["isActive"] as? Bool {
                    isActive = String(active)
                }
            } catch {
                print("[RemoveEmployee][CALL] uid=\(uid) profileLookupError=\(error.localizedDescription)")
            }
        }

        print("[RemoveEmployee][CALL] operation=removeEmployeeFromStore uid=\(uid) providerIDs=\(providerIDs) role=\(role) isActive=\(isActive) path=stores/\(storeId)/members/\(employeeId)")
    }

    private func isFirestorePermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain && nsError.code == 7
    }

    private func logFunctionsErrorIfPresent(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == "com.firebase.functions" || nsError.domain == "FunctionsErrorDomain" {
            let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription
            let userInfoKeys = Array(nsError.userInfo.keys).map { String(describing: $0) }.sorted()
            print("[RemoveEmployee][FAIL] domain=\(nsError.domain) code=\(nsError.code) message=\(message) userInfoKeys=\(userInfoKeys)")
            print("[RemoveEmployee][FAIL] function=\(removeEmployeeFunctionName) region=\(removeEmployeeFunctionRegion)")
            return
        }

        print("[RemoveEmployee][FAIL] domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription) details=\(nsError.userInfo)")
        print("[RemoveEmployee][FAIL] function=\(removeEmployeeFunctionName) region=\(removeEmployeeFunctionRegion)")
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
