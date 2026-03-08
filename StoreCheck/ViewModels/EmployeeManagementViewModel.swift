import Foundation

@MainActor
final class EmployeeManagementViewModel: ObservableObject {
    struct EmployeeWorkSummary: Hashable {
        let approvedCompletedSessions: Int
        let totalWorkedSeconds: Int
    }

    static let allStoresFilter = "all"

    @Published var stores: [Store] = []
    @Published var employees: [EmployeeSummary] = []
    @Published var selectedStoreId: String = EmployeeManagementViewModel.allStoresFilter
    @Published var employeeError: String?
    @Published var successMessage: String?
    @Published var bannerMessage: String?
    @Published var isLoading = false
    @Published private(set) var pendingRemoval: PendingRemoval?
    @Published private(set) var workSummaryByEmployeeId: [String: EmployeeWorkSummary] = [:]
    @Published private(set) var loadingWorkSummaryEmployeeIds: Set<String> = []

    private let employeeRepository: EmployeeManagementRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol
    private let checkInRepository: CheckInRepositoryProtocol

    private static let earningsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    init(
        employeeRepository: EmployeeManagementRepositoryProtocol,
        authRepository: AuthRepositoryProtocol,
        checkInRepository: CheckInRepositoryProtocol
    ) {
        self.employeeRepository = employeeRepository
        self.authRepository = authRepository
        self.checkInRepository = checkInRepository
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

    func employee(withId employeeId: String) -> EmployeeSummary? {
        employees.first(where: { $0.id == employeeId })
    }

    func hourlyRateText(for employee: EmployeeSummary) -> String {
        guard let cents = employee.hourlyRateCents else {
            return "Not set"
        }
        let amount = Decimal(cents) / 100
        return "$\(NSDecimalNumber(decimal: amount).stringValue)/hr"
    }

    func totalHoursText(for employeeId: String) -> String {
        if loadingWorkSummaryEmployeeIds.contains(employeeId), workSummaryByEmployeeId[employeeId] == nil {
            return "Calculating..."
        }

        guard let summary = workSummaryByEmployeeId[employeeId] else {
            return "—"
        }

        let totalHours = Double(summary.totalWorkedSeconds) / 3600
        return String(format: "%.2f h", totalHours)
    }

    func totalEarningsText(for employee: EmployeeSummary) -> String {
        if loadingWorkSummaryEmployeeIds.contains(employee.id), workSummaryByEmployeeId[employee.id] == nil {
            return "Calculating..."
        }

        guard let summary = workSummaryByEmployeeId[employee.id] else {
            return "—"
        }

        guard let hourlyRateCents = employee.hourlyRateCents else {
            return "Set hourly salary"
        }

        let dollars = (Double(summary.totalWorkedSeconds) / 3600) * (Double(hourlyRateCents) / 100)
        return Self.earningsFormatter.string(from: NSNumber(value: dollars)) ?? "$0.00"
    }

    func approvedSessionsText(for employeeId: String) -> String {
        if loadingWorkSummaryEmployeeIds.contains(employeeId), workSummaryByEmployeeId[employeeId] == nil {
            return "Loading..."
        }

        guard let summary = workSummaryByEmployeeId[employeeId] else {
            return "—"
        }

        return "\(summary.approvedCompletedSessions)"
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
            let currentEmployeeIds = Set(employees.map(\.id))
            workSummaryByEmployeeId = workSummaryByEmployeeId.filter { currentEmployeeIds.contains($0.key) }
            loadingWorkSummaryEmployeeIds = loadingWorkSummaryEmployeeIds.intersection(currentEmployeeIds)
            employeeError = nil
        } catch {
            employeeError = error.localizedDescription
            AppLog.error("Failed loading employees", error: error)
        }
    }

    func clearWorkSummaryCache() {
        workSummaryByEmployeeId.removeAll()
        loadingWorkSummaryEmployeeIds.removeAll()
    }

    func prepareRemoval(for employee: EmployeeSummary, preferredStoreId: String? = nil) {
        let targetStoreId: String

        if let preferredStoreId,
           employee.storeIds.contains(preferredStoreId) {
            targetStoreId = preferredStoreId
        } else if selectedStoreId == Self.allStoresFilter {
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
            clearWorkSummaryCache()
            await load()
            NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil)
        } catch {
            employeeError = error.localizedDescription
            AppLog.error("Failed removing employee from store", error: error)
        }
    }

    func setActive(employeeId: String, isActive: Bool) async {
        do {
            try await employeeRepository.setEmployeeActive(employeeId: employeeId, isActive: isActive)
            clearWorkSummaryCache()
            await load()
        } catch {
            employeeError = error.localizedDescription
            AppLog.error("Failed updating employee active status", error: error)
        }
    }

    func updateEmployeeProfile(
        employeeId: String,
        name: String,
        hourlyRateCents: Int?,
        expectedStartMinutesFromMidnight: Int?
    ) async {
        do {
            try await employeeRepository.updateEmployeeProfile(
                employeeId: employeeId,
                name: name,
                hourlyRateCents: hourlyRateCents,
                expectedStartMinutesFromMidnight: expectedStartMinutesFromMidnight
            )
            successMessage = "Employee profile updated."
            clearWorkSummaryCache()
            await load()
        } catch {
            employeeError = error.localizedDescription
            AppLog.error("Failed updating employee profile", error: error)
        }
    }

    func loadWorkSummary(for employee: EmployeeSummary) async {
        guard !loadingWorkSummaryEmployeeIds.contains(employee.id) else { return }
        loadingWorkSummaryEmployeeIds.insert(employee.id)
        defer { loadingWorkSummaryEmployeeIds.remove(employee.id) }

        do {
            let checkIns = try await checkInRepository.fetchEmployeeCheckIns(employeeId: employee.id, limit: 2_000)
            let managerStoreIds = Set(employee.storeIds)
            let approvedSessions = checkIns.filter { checkIn in
                guard managerStoreIds.contains(checkIn.storeId), checkIn.status == .approved else {
                    return false
                }
                return (checkIn.computedDurationSeconds ?? 0) > 0
            }

            let totalSeconds = approvedSessions.reduce(0) { partial, checkIn in
                partial + max(checkIn.computedDurationSeconds ?? 0, 0)
            }

            workSummaryByEmployeeId[employee.id] = EmployeeWorkSummary(
                approvedCompletedSessions: approvedSessions.count,
                totalWorkedSeconds: totalSeconds
            )
        } catch {
            AppLog.warning("Failed loading employee work summary id=\(AppLog.redactIdentifier(employee.id)): \(AppLog.sanitize(error.localizedDescription))")
        }
    }
}
