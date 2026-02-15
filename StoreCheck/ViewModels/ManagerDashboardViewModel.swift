import Foundation

@MainActor
final class ManagerDashboardViewModel: ObservableObject {
    @Published var checkIns: [CheckIn] = []
    @Published var selectedStore: String = "All"
    @Published var selectedStatus: String = "All"

    private let checkInRepository: CheckInRepositoryProtocol

    init(checkInRepository: CheckInRepositoryProtocol) {
        self.checkInRepository = checkInRepository
    }

    func load() async {
        do {
            let all = try await checkInRepository.fetchTodaysCheckIns()
            checkIns = all.filter {
                (selectedStore == "All" || $0.storeName == selectedStore) &&
                (selectedStatus == "All" || $0.status.rawValue == selectedStatus)
            }
        } catch {
            checkIns = []
        }
    }
}
