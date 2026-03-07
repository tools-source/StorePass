import Foundation
import CloudKit

@MainActor
final class AppContainer: ObservableObject {
    let authService: AuthService
    let cloudKitService: CloudKitService
    let userProfileStore: UserProfileStoreProtocol
    let cloudKitSanityChecker: CloudKitSanityChecking

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
        let cloudKitContainer = Self.resolveCloudKitContainer()
        let cloudKitService = CloudKitService(
            container: cloudKitContainer,
            authService: authService
        )
        let userProfileStore = CloudKitUserProfileStore(service: cloudKitService)
        let userRepository = CloudKitUserRepository(service: cloudKitService, profileStore: userProfileStore)
        let cloudKitSanityChecker = CloudKitSanityChecker(service: cloudKitService)

        self.authService = authService
        self.cloudKitService = cloudKitService
        self.userProfileStore = userProfileStore
        self.cloudKitSanityChecker = cloudKitSanityChecker
        self.authRepository = CloudKitAuthRepository(authService: authService)

        #if DEBUG
        if DebugOptions.isUITestingEnabled {
            let uiRoleProfiles = UITestRoleProfileRepository()
            let uiStoreRepository = UITestStoreRepository(authService: authService, roleProfiles: uiRoleProfiles)
            self.userRepository = UITestUserRepository(roleProfiles: uiRoleProfiles)
            self.roleProfileRepository = uiRoleProfiles
            self.employeeManagementRepository = UITestEmployeeManagementRepository(roleProfiles: uiRoleProfiles, stores: uiStoreRepository)
            self.storeRepository = uiStoreRepository
            self.checkInRepository = UITestCheckInRepository()
        } else {
            self.userRepository = userRepository
            self.roleProfileRepository = CloudKitRoleProfileRepository(service: cloudKitService, profileStore: userProfileStore)
            self.employeeManagementRepository = CloudKitEmployeeManagementRepository(service: cloudKitService, profileStore: userProfileStore)
            self.storeRepository = CloudKitStoreRepository(service: cloudKitService, authService: authService, userProfileStore: userProfileStore)
            self.checkInRepository = CloudKitCheckInRepository(service: cloudKitService, userProfileStore: userProfileStore)
        }
        #else
        self.userRepository = userRepository
        self.roleProfileRepository = CloudKitRoleProfileRepository(service: cloudKitService, profileStore: userProfileStore)
        self.employeeManagementRepository = CloudKitEmployeeManagementRepository(service: cloudKitService, profileStore: userProfileStore)
        self.storeRepository = CloudKitStoreRepository(service: cloudKitService, authService: authService, userProfileStore: userProfileStore)
        self.checkInRepository = CloudKitCheckInRepository(service: cloudKitService, userProfileStore: userProfileStore)
        #endif

        let locationService = LocationService()
        self.locationService = locationService
        self.csvExporter = CSVExportService()
        self.offlineQueue = OfflineCheckInQueue()
        self.checkInService = CheckInService(locationService: locationService)
    }

    private static func resolveCloudKitContainer() -> CKContainer {
        if let override = ProcessInfo.processInfo.environment["STOREPASS_CLOUDKIT_CONTAINER_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            AppLog.info("CloudKit container override active id=\(override)")
            return CKContainer(identifier: override)
        }

        if let infoOverride = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String {
            let trimmed = infoOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                AppLog.info("CloudKit container Info.plist override active id=\(trimmed)")
                return CKContainer(identifier: trimmed)
            }
        }

        let signing = SigningDiagnostics.snapshot()
        if !signing.iCloudContainerIdentifiers.isEmpty {
            AppLog.info(
                "Signed CloudKit entitlements appIdentifier=\(signing.applicationIdentifier ?? "unknown") " +
                "containers=\(signing.iCloudContainerIdentifiers.joined(separator: ","))"
            )
        } else {
            AppLog.warning("Signed CloudKit entitlements are missing container identifiers.")
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let derivedContainerID = "iCloud.\(bundleID)"

        if signing.iCloudContainerIdentifiers.count == 1, let only = signing.iCloudContainerIdentifiers.first {
            AppLog.info("CloudKit container resolved from signed entitlement id=\(only)")
            return CKContainer(identifier: only)
        }

        if signing.iCloudContainerIdentifiers.contains(derivedContainerID) {
            AppLog.info("CloudKit container resolved from bundle-derived id=\(derivedContainerID)")
            return CKContainer(identifier: derivedContainerID)
        }

        if let first = signing.iCloudContainerIdentifiers.first {
            AppLog.warning(
                "Bundle-derived container \(derivedContainerID) not found in entitlements; " +
                "falling back to first entitled container \(first)."
            )
            return CKContainer(identifier: first)
        }

        AppLog.warning("Falling back to bundle-derived CloudKit container id=\(derivedContainerID)")
        return CKContainer(identifier: derivedContainerID)
    }
}
