import Foundation
import UIKit

@MainActor
final class ManagerCheckInsViewModel: ObservableObject {
    struct EmployeeFilterOption: Identifiable, Hashable {
        let id: String
        let label: String
    }

    struct DaySection: Identifiable {
        let day: Date
        let items: [CheckIn]

        var id: Date { day }

        var dailyTotalSeconds: Int {
            items.compactMap(\.computedDurationSeconds).reduce(0, +)
        }
    }

    static let allEmployeesId = "__all_employees__"

    @Published var stores: [Store] = []
    @Published var selectedStoreId: String?
    @Published var selectedEmployeeId: String = allEmployeesId
    @Published var checkIns: [CheckIn] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showOpenSessionsOnly = false

    private let storeRepository: StoreRepositoryProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol
    private let csvExporter: CSVExportServiceProtocol

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    init(
        storeRepository: StoreRepositoryProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        authRepository: AuthRepositoryProtocol,
        csvExporter: CSVExportServiceProtocol
    ) {
        self.storeRepository = storeRepository
        self.checkInRepository = checkInRepository
        self.authRepository = authRepository
        self.csvExporter = csvExporter
    }

    var employeeOptions: [EmployeeFilterOption] {
        let grouped = Dictionary(grouping: checkIns) { $0.employeeId }
        let mapped = grouped.compactMap { employeeId, items -> EmployeeFilterOption? in
            guard let first = items.first else { return nil }
            let label = first.employeeName.isEmpty ? (first.employeeEmail ?? employeeId) : first.employeeName
            return EmployeeFilterOption(id: employeeId, label: label)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        return [EmployeeFilterOption(id: Self.allEmployeesId, label: "All employees")] + mapped
    }

    var visibleCheckIns: [CheckIn] {
        checkIns.filter { item in
            let isOpenMatch = !showOpenSessionsOnly || item.checkOutTime == nil
            let isEmployeeMatch = selectedEmployeeId == Self.allEmployeesId || item.employeeId == selectedEmployeeId
            return isOpenMatch && isEmployeeMatch
        }
    }

    var daySections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleCheckIns) { calendar.startOfDay(for: $0.checkInTime) }

        return grouped
            .map { day, items in
                let sortedItems = items.sorted { $0.checkInTime > $1.checkInTime }
                return DaySection(day: day, items: sortedItems)
            }
            .sorted { $0.day > $1.day }
    }

    var selectedStoreName: String {
        stores.first(where: { $0.id == selectedStoreId })?.name ?? "Select store"
    }

    var selectedEmployeeName: String {
        employeeOptions.first(where: { $0.id == selectedEmployeeId })?.label ?? "All employees"
    }

    func load() async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let managerStores = try await storeRepository.fetchManagerStores(managerId: managerId)
            stores = managerStores

            if selectedStoreId == nil || !managerStores.contains(where: { $0.id == selectedStoreId }) {
                selectedStoreId = managerStores.first?.id
            }

            guard let storeId = selectedStoreId else {
                checkIns = []
                errorMessage = nil
                selectedEmployeeId = Self.allEmployeesId
                return
            }

            checkIns = try await checkInRepository.fetchManagerStoreCheckIns(managerId: managerId, storeId: storeId, limit: 200)
            if !employeeOptions.contains(where: { $0.id == selectedEmployeeId }) {
                selectedEmployeeId = Self.allEmployeesId
            }
#if DEBUG
            let employeeIds = Set(checkIns.map(\.employeeId)).sorted()
            print("[ManagerCheckIns] loaded=\(checkIns.count) distinctEmployeeIds=\(employeeIds) selectedEmployee=\(selectedEmployeeId)")
#endif
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ checkIn: CheckIn, status: CheckInStatus, reason: String?) async {
        var updated = checkIn
        updated.status = status
        updated.rejectReason = reason
        do {
            try await checkInRepository.updateCheckIn(updated)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ checkIn: CheckIn) async {
        guard let managerId = authRepository.currentUserId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        do {
            try await checkInRepository.deleteCheckIn(
                checkinId: checkIn.id,
                storeId: checkIn.storeId,
                managerId: managerId
            )
            checkIns.removeAll { $0.id == checkIn.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAllForSelectedStore() async {
        guard let managerId = authRepository.currentUserId,
              let storeId = selectedStoreId else {
            errorMessage = "Unable to resolve current manager session."
            return
        }

        do {
            try await checkInRepository.clearAllCheckIns(storeId: storeId, managerId: managerId, limit: 500)
            checkIns.removeAll { $0.storeId == storeId }
            selectedEmployeeId = Self.allEmployeesId
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyVisibleList() {
        UIPasteboard.general.string = csvExporter.generateCSVText(from: visibleCheckIns)
    }

    func exportURL() -> URL? {
        let store = stores.first(where: { $0.id == selectedStoreId })?.name ?? "store"
        return csvExporter.generateCSV(from: visibleCheckIns, filePrefix: "checkins_\(store)")
    }

    func formattedTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    func formattedDay(_ date: Date) -> String {
        date.timesheetDayString()
    }

    func formattedDuration(_ checkIn: CheckIn) -> String {
        guard let seconds = checkIn.computedDurationSeconds else { return "—" }
        return formattedDuration(seconds: seconds)
    }

    func formattedDuration(seconds: Int) -> String {
        let clamped = max(seconds, 0)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
