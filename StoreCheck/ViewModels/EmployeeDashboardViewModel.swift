import Foundation

@MainActor
final class EmployeeDashboardViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var selectedStore: Store?
    @Published var locationStatus: LocationCheckState = .unknown
    @Published var todayStatus: String = "Not checked in"
    @Published var errorMessage: String?

    private let authService: AuthService
    private let storeRepository: StoreRepositoryProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let checkInService: CheckInServiceProtocol
    private let locationService: LocationServiceProtocol

    init(
        authService: AuthService,
        storeRepository: StoreRepositoryProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        locationService: LocationServiceProtocol
    ) {
        self.authService = authService
        self.storeRepository = storeRepository
        self.checkInRepository = checkInRepository
        self.checkInService = checkInService
        self.locationService = locationService
    }

    func load() async {
        guard let user = authService.currentUser else { return }
        do {
            stores = try await storeRepository.fetchStores(ids: user.assignedStoreIds)
            selectedStore = stores.first
            try await refreshTodayStatus(userId: user.id)
            refreshLocationStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestLocation() {
        locationService.requestWhenInUseAuthorization()
        locationService.requestLocation()
        refreshLocationStatus()
    }

    func refreshLocationStatus() {
        guard let selectedStore else { return }
        locationStatus = checkInService.evaluateLocation(for: selectedStore)
    }

    func checkIn() async -> Bool {
        guard let user = authService.currentUser, let selectedStore else { return false }
        do {
            _ = try await checkInService.submitCheckIn(user: user, store: selectedStore)
            try await refreshTodayStatus(userId: user.id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshTodayStatus(userId: String) async throws {
        let checkins = try await checkInRepository.fetchCheckIns(employeeId: userId, limit: 30)
        let today = Calendar.current.isDateInToday
        todayStatus = checkins.contains(where: { today($0.checkInTime) && $0.status == .approved }) ? "Checked in" : "Not checked in"
    }
}
