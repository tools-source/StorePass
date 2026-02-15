import Foundation

@MainActor
final class ManagerDashboardViewModel: ObservableObject {
    @Published var checkIns: [CheckIn] = []
    @Published var selectedStoreId: String = ""
    @Published var selectedStatus: CheckInStatus?
    @Published var selectedDate: Date = Date()
    @Published var errorMessage: String?

    private let checkInRepository: CheckInRepositoryProtocol

    init(checkInRepository: CheckInRepositoryProtocol) {
        self.checkInRepository = checkInRepository
    }

    func load() async {
        do {
            let filter = CheckInFilter(storeId: selectedStoreId.isEmpty ? nil : selectedStoreId, status: selectedStatus, date: selectedDate)
            checkIns = try await checkInRepository.fetchTodaysCheckIns(filter: filter)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
