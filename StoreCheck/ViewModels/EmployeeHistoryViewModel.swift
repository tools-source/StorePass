import Foundation

@MainActor
final class EmployeeHistoryViewModel: ObservableObject {
    @Published var checkIns: [CheckIn] = []
    @Published var selectedStoreId: String?

    private let authService: AuthService
    private let checkInRepository: CheckInRepositoryProtocol

    init(authService: AuthService, checkInRepository: CheckInRepositoryProtocol) {
        self.authService = authService
        self.checkInRepository = checkInRepository
    }

    func load() async {
        guard let id = authService.currentUser?.id else { return }
        do {
            let all = try await checkInRepository.fetchCheckIns(employeeId: id, limit: 30)
            checkIns = selectedStoreId == nil ? all : all.filter { $0.storeId == selectedStoreId }
        } catch {
            checkIns = []
        }
    }
}
