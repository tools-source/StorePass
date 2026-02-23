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

    private let authService: AuthService
    private let checkInRepository: CheckInRepositoryProtocol
    private let csvExporter: CSVExportServiceProtocol

    init(authService: AuthService, checkInRepository: CheckInRepositoryProtocol, csvExporter: CSVExportServiceProtocol) {
        self.authService = authService
        self.checkInRepository = checkInRepository
        self.csvExporter = csvExporter
    }

    var visibleCheckIns: [CheckIn] {
        checkIns.filter { Calendar.current.isDate($0.checkInTime, inSameDayAs: selectedDate) }
    }

    var dailyTotalSeconds: Int {
        visibleCheckIns.compactMap(\.computedDurationSeconds).reduce(0, +)
    }

    func load() async {
        guard let id = authService.currentUser?.id else { return }
        do {
            checkIns = try await checkInRepository.fetchEmployeeCheckIns(employeeId: id, limit: 100)
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
        UIPasteboard.general.string = csvText(for: visibleCheckIns)
    }

    func copySingle(_ checkIn: CheckIn) {
        UIPasteboard.general.string = csvText(for: [checkIn])
    }

    func exportURL() -> URL? {
        csvExporter.generateCSV(from: visibleCheckIns, filePrefix: "checkins_\(authService.currentUser?.name ?? "employee")")
    }

    func formattedDuration(seconds: Int) -> String {
        DurationFormatter.clockString(from: seconds)
    }

    private func csvText(for items: [CheckIn]) -> String {
        csvExporter.generateCSVText(from: items)
    }
}
