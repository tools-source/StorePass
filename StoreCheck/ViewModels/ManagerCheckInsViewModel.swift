import Foundation
import UIKit

@MainActor
final class ManagerCheckInsViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var selectedStoreId: String?
    @Published var checkIns: [CheckIn] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showOpenSessionsOnly = false

    private let storeRepository: StoreRepositoryProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let authRepository: AuthRepositoryProtocol
    private let csvExporter: CSVExportServiceProtocol

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

    var visibleCheckIns: [CheckIn] {
        showOpenSessionsOnly ? checkIns.filter { $0.checkOutTime == nil } : checkIns
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
                return
            }

            checkIns = try await checkInRepository.fetchManagerStoreCheckIns(managerId: managerId, storeId: storeId, limit: 200)
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
            try await checkInRepository.deleteCheckIn(
                checkinId: checkIn.id,
                employeeId: checkIn.employeeId,
                storeId: checkIn.storeId,
                managerId: authRepository.currentUserId
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAllForSelectedStore() async {
        do {
            try await checkInRepository.clearAllCheckIns(isManagerScope: true, storeId: selectedStoreId, managerId: authRepository.currentUserId)
            await load()
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

    func formattedDuration(_ checkIn: CheckIn) -> String {
        guard let seconds = checkIn.computedDurationSeconds else { return "Open" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return "\(hours)h \(minutes)m"
    }
}
