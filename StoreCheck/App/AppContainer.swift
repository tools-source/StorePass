import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let authService: AuthService
    let cloudKitService: CloudKitService
    let userProfileStore: UserProfileStoreProtocol

    let authRepository: AuthRepositoryProtocol
    let userRepository: UserRepositoryProtocol
    let roleProfileRepository: RoleProfileRepositoryProtocol
    let employeeManagementRepository: EmployeeManagementRepositoryProtocol
    let storeRepository: StoreRepositoryProtocol
    let checkInRepository: CheckInRepositoryProtocol

    let locationService: LocationService
    let csvExporter: CSVExportServiceProtocol
    let offlineQueue: OfflineCheckInQueueProtocol
    let checkInService: CheckInServiceProtocol

    init() {
        let authService = AuthService()
        let cloudKitService = CloudKitService(authService: authService)
        let userProfileStore = CloudKitUserProfileStore(service: cloudKitService)
        let userRepository = CloudKitUserRepository(service: cloudKitService, profileStore: userProfileStore)

        self.authService = authService
        self.cloudKitService = cloudKitService
        self.userProfileStore = userProfileStore
        self.authRepository = CloudKitAuthRepository(authService: authService)
        self.userRepository = userRepository
        self.roleProfileRepository = CloudKitRoleProfileRepository(service: cloudKitService, profileStore: userProfileStore)
        self.employeeManagementRepository = CloudKitEmployeeManagementRepository(service: cloudKitService, profileStore: userProfileStore)
        self.storeRepository = CloudKitStoreRepository(service: cloudKitService, authService: authService, userProfileStore: userProfileStore)
        self.checkInRepository = CloudKitCheckInRepository(service: cloudKitService, userProfileStore: userProfileStore)

        let locationService = LocationService()
        self.locationService = locationService
        self.csvExporter = CSVExportService()
        self.offlineQueue = OfflineCheckInQueue()
        self.checkInService = CheckInService(locationService: locationService)
    }
}
