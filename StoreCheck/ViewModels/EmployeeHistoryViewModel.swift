import Foundation

@MainActor
final class EmployeeHistoryViewModel: ObservableObject {
    @Published var checkIns: [CheckIn] = []
    @Published var errorMessage: String?

    private let authService: AuthService
    private let checkInRepository: CheckInRepositoryProtocol

    init(authService: AuthService, checkInRepository: CheckInRepositoryProtocol) {
        self.authService = authService
        self.checkInRepository = checkInRepository
    }

    func load() async {
        guard let id = authService.currentUser?.id else { return }
        do {
            checkIns = try await checkInRepository.fetchCheckIns(employeeId: id, limit: 30)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
