import Foundation

@MainActor
final class EmployeeDashboardViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var selectedStore: Store?
    @Published var locationStatus: LocationCheckState = .unknown
    @Published var errorMessage: String?
    @Published var checkInSuccessBanner = false

    private let authService: AuthService
    private let storeRepository: StoreRepositoryProtocol
    private let checkInService: CheckInServiceProtocol
    private let locationService: LocationServiceProtocol

    init(
        authService: AuthService,
        storeRepository: StoreRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        locationService: LocationServiceProtocol
    ) {
        self.authService = authService
        self.storeRepository = storeRepository
        self.checkInService = checkInService
        self.locationService = locationService
    }

    var blockedReason: String? {
        checkInService.blockedReason(for: locationStatus, user: authService.currentUser, store: selectedStore)
    }

    func load() async {
        guard let user = authService.currentUser else { return }
        do {
            stores = try await storeRepository.fetchStores(ids: user.assignedStoreIds)
            selectedStore = selectedStore ?? stores.first
            refreshLocation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLocation() {
        guard let selectedStore else { return }
        locationService.requestWhenInUseAuthorization()
        locationService.requestLocation()
        locationStatus = checkInService.evaluateLocation(for: selectedStore, user: authService.currentUser)
        if let locationError = locationService.lastErrorMessage {
            errorMessage = locationError
        }
    }

    func checkIn() async {
        guard let user = authService.currentUser, let store = selectedStore else { return }
        do {
            _ = try await checkInService.submitCheckIn(user: user, store: store)
            checkInSuccessBanner = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
