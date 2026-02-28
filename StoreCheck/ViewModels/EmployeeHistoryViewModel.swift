import Foundation
import UIKit

enum DurationFormatter {
    static func clockString(from seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let hours = safeSeconds / 3600
        let minutes = (safeSeconds % 3600) / 60
        let remainingSeconds = safeSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }
}

@MainActor
final class EmployeeHistoryViewModel: ObservableObject {
    @Published var checkIns: [CheckIn] = []
    @Published var errorMessage: String?
    @Published var selectedDate: Date = Date()
    @Published var selectedStoreId: String?

    private let authService: AuthService
    private let checkInRepository: CheckInRepositoryProtocol
    private let csvExporter: CSVExportServiceProtocol

    init(authService: AuthService, checkInRepository: CheckInRepositoryProtocol, csvExporter: CSVExportServiceProtocol) {
        self.authService = authService
        self.checkInRepository = checkInRepository
        self.csvExporter = csvExporter
    }

    var visibleCheckIns: [CheckIn] {
        checkIns.filter { item in
            let isSelectedDay = Calendar.current.isDate(item.checkInTime, inSameDayAs: selectedDate)
            let isSelectedStore = selectedStoreId == nil || item.storeId == selectedStoreId
            return isSelectedDay && isSelectedStore
        }
    }


    struct StoreFilterOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    var storeOptions: [StoreFilterOption] {
        let options = Dictionary(grouping: checkIns, by: \.storeId)
            .compactMap { storeId, entries -> StoreFilterOption? in
                guard let first = entries.first else { return nil }
                return StoreFilterOption(id: storeId, name: first.storeName)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return options
    }

    var selectedStoreName: String {
        storeOptions.first(where: { $0.id == selectedStoreId })?.name ?? storeOptions.first?.name ?? "Store"
    }

    var hasMultipleStores: Bool {
        storeOptions.count > 1
    }

    var dailyTotalSeconds: Int {
        visibleCheckIns.compactMap(\.computedDurationSeconds).reduce(0, +)
    }

    func load() async {
        guard let id = authService.currentUser?.id else { return }
        do {
            checkIns = try await checkInRepository.fetchEmployeeCheckIns(employeeId: id, limit: 100)
            if selectedStoreId == nil || !storeOptions.contains(where: { $0.id == selectedStoreId }) {
                selectedStoreId = storeOptions.first?.id
            }
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
        do {
            try await checkInRepository.deleteCheckIn(checkinId: checkIn.id, employeeId: checkIn.employeeId, storeId: checkIn.storeId, managerId: nil)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAll() async {
        do {
            try await checkInRepository.clearAllCheckIns(isManagerScope: false, storeId: nil, managerId: nil)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyAllVisible() {
        copy(items: visibleCheckIns)
    }

    func copySingle(_ checkIn: CheckIn) {
        copy(items: [checkIn])
    }

    func copy(items: [CheckIn]) {
        UIPasteboard.general.string = csvText(for: items)
    }

    func exportURL() -> URL? {
        exportURL(for: visibleCheckIns)
    }

    func exportURL(for items: [CheckIn]) -> URL? {
        csvExporter.generateCSV(from: items, filePrefix: "checkins_\(authService.currentUser?.name ?? "employee")")
    }

    func formattedDuration(seconds: Int) -> String {
        DurationFormatter.clockString(from: seconds)
    }

    private func csvText(for items: [CheckIn]) -> String {
        csvExporter.generateCSVText(from: items)
    }
}
