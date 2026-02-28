import Foundation

@MainActor
final class AppContainer: ObservableObject {
    private let authRepositoryFactory: () -> AuthRepositoryProtocol
    private let userRepositoryFactory: () -> UserRepositoryProtocol
    private let roleProfileRepositoryFactory: () -> RoleProfileRepositoryProtocol
    private let employeeManagementRepositoryFactory: () -> EmployeeManagementRepositoryProtocol
    private let storeRepositoryFactory: () -> StoreRepositoryProtocol
    private let checkInRepositoryFactory: () -> CheckInRepositoryProtocol
    private let locationServiceFactory: () -> LocationService
    private let csvExporterFactory: () -> CSVExportServiceProtocol
    private let offlineQueueFactory: () -> OfflineCheckInQueueProtocol

    lazy var authRepository: AuthRepositoryProtocol = authRepositoryFactory()
    lazy var userRepository: UserRepositoryProtocol = userRepositoryFactory()
    lazy var roleProfileRepository: RoleProfileRepositoryProtocol = roleProfileRepositoryFactory()
    lazy var employeeManagementRepository: EmployeeManagementRepositoryProtocol = employeeManagementRepositoryFactory()
    lazy var storeRepository: StoreRepositoryProtocol = storeRepositoryFactory()
    lazy var checkInRepository: CheckInRepositoryProtocol = checkInRepositoryFactory()
    lazy var locationService: LocationService = locationServiceFactory()
    lazy var csvExporter: CSVExportServiceProtocol = csvExporterFactory()
    lazy var offlineQueue: OfflineCheckInQueueProtocol = offlineQueueFactory()

    lazy var authService: AuthService = AuthService()

    lazy var checkInService: CheckInServiceProtocol = CheckInService(
        userRepository: userRepository,
        storeRepository: storeRepository,
        checkInRepository: checkInRepository,
        locationService: locationService,
        offlineQueue: offlineQueue
    )


    init(
        authRepositoryFactory: @escaping () -> AuthRepositoryProtocol = { FirebaseAuthRepository() },
        userRepositoryFactory: @escaping () -> UserRepositoryProtocol = { FirestoreUserRepository() },
        roleProfileRepositoryFactory: @escaping () -> RoleProfileRepositoryProtocol = { FirestoreRoleProfileRepository() },
        employeeManagementRepositoryFactory: @escaping () -> EmployeeManagementRepositoryProtocol = { FirestoreEmployeeManagementRepository() },
        storeRepositoryFactory: @escaping () -> StoreRepositoryProtocol = { FirestoreStoreRepository() },
        checkInRepositoryFactory: @escaping () -> CheckInRepositoryProtocol = { FirestoreCheckInRepository() },
        locationServiceFactory: @escaping () -> LocationService = { LocationService() },
        csvExporterFactory: @escaping () -> CSVExportServiceProtocol = { CSVExportService() },
        offlineQueueFactory: @escaping () -> OfflineCheckInQueueProtocol = { OfflineCheckInQueue() }
    ) {
        self.authRepositoryFactory = authRepositoryFactory
        self.userRepositoryFactory = userRepositoryFactory
        self.roleProfileRepositoryFactory = roleProfileRepositoryFactory
        self.employeeManagementRepositoryFactory = employeeManagementRepositoryFactory
        self.storeRepositoryFactory = storeRepositoryFactory
        self.checkInRepositoryFactory = checkInRepositoryFactory
        self.locationServiceFactory = locationServiceFactory
        self.csvExporterFactory = csvExporterFactory
        self.offlineQueueFactory = offlineQueueFactory
    }
}
