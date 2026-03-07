import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let authService: AuthService
    let cloudKitService: CloudKitService

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
        let userRepository = CloudKitUserRepository(service: cloudKitService)

        self.authService = authService
        self.cloudKitService = cloudKitService
        self.authRepository = CloudKitAuthRepository(authService: authService)
        self.userRepository = userRepository
        self.roleProfileRepository = CloudKitRoleProfileRepository(service: cloudKitService)
        self.employeeManagementRepository = CloudKitEmployeeManagementRepository(service: cloudKitService)
        self.storeRepository = CloudKitStoreRepository(service: cloudKitService)
        self.checkInRepository = CloudKitCheckInRepository(service: cloudKitService)

        let locationService = LocationService()
        self.locationService = locationService
        self.csvExporter = CSVExportService()
        self.offlineQueue = OfflineCheckInQueue()
        self.checkInService = CheckInService(locationService: locationService)
    }
}
