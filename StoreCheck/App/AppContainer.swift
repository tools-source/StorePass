import Foundation

@MainActor
final class AppContainer: ObservableObject {
    static let shared = AppContainer()
    let authRepository: AuthRepositoryProtocol
    let userRepository: UserRepositoryProtocol
    let storeRepository: StoreRepositoryProtocol
    let checkInRepository: CheckInRepositoryProtocol
    let authService: AuthServiceProtocol
    let locationService: LocationServiceProtocol
    let checkInService: CheckInServiceProtocol
    let csvExporter: CSVExportServiceProtocol
    let offlineQueue: OfflineCheckInQueueProtocol

    init(
        authRepository: AuthRepositoryProtocol = FirebaseAuthRepository(),
        userRepository: UserRepositoryProtocol = FirestoreUserRepository(),
        storeRepository: StoreRepositoryProtocol = FirestoreStoreRepository(),
        checkInRepository: CheckInRepositoryProtocol = FirestoreCheckInRepository(),
        locationService: LocationServiceProtocol = LocationService(),
        csvExporter: CSVExportServiceProtocol = CSVExportService(),
        offlineQueue: OfflineCheckInQueueProtocol = OfflineCheckInQueue()
    ) {
        self.authRepository = authRepository
        self.userRepository = userRepository
        self.storeRepository = storeRepository
        self.checkInRepository = checkInRepository
        self.locationService = locationService
        self.csvExporter = csvExporter
        self.offlineQueue = offlineQueue
        self.authService = AuthService()
        self.checkInService = CheckInService(
            userRepository: userRepository,
            storeRepository: storeRepository,
            checkInRepository: checkInRepository,
            locationService: locationService,
            offlineQueue: offlineQueue
        )
    }
}
