import AuthenticationServices
import CoreLocation
import XCTest
@testable import StoreCheck

@MainActor
final class EmployeeDashboardViewModelTests: XCTestCase {
    func testJoinStoreByCodeUpdatesAssignedStoreIdsAndVisibleStores() async {
        let authService = MockDashboardAuthService(
            user: UserProfile(
                id: "employee-1",
                name: "Avery",
                email: "avery@storepass.app",
                role: .employee,
                createdAt: Date(),
                lastLoginAt: Date(),
                provider: "manual.employee",
                assignedStoreIds: [],
                isActive: true
            )
        )

        let store = Store(
            id: "store-1",
            name: "Downtown",
            address: "1 Main St",
            latitude: 40.7128,
            longitude: -74.0060,
            radiusMeters: 150,
            isActive: true,
            managerId: "manager-1",
            createdAt: Date(),
            updatedAt: Date(),
            joinCode: "ABCD1234",
            joinCodeCiphertext: "ABCD1234",
            joinCodeLast4: "1234"
        )

        let storeRepository = MockStoreRepository()
        storeRepository.joinResult = JoinStoreResult(
            storeId: store.id,
            storeName: store.name,
            alreadyJoined: false,
            assignedStoreIds: [store.id]
        )
        storeRepository.storesByID[store.id] = store

        let checkInRepository = MockCheckInRepository()
        let locationService = MockLocationService()
        let checkInService = MockCheckInService()

        let viewModel = EmployeeDashboardViewModel(
            authService: authService,
            storeRepository: storeRepository,
            checkInService: checkInService,
            checkInRepository: checkInRepository,
            locationService: locationService,
            verifyReadDelayNanoseconds: 0
        )

        viewModel.joinCodeInput = "ABCD1234"
        await viewModel.joinStoreByCode()

        XCTAssertEqual(authService.currentUser?.assignedStoreIds, [store.id])
        XCTAssertEqual(viewModel.stores.map(\.id), [store.id])
        XCTAssertEqual(viewModel.joinCodeInput, "")
        XCTAssertEqual(viewModel.joinStatusMessage, "Joined Downtown.")
    }

    func testCheckInThenCheckOutFlow() async {
        let user = UserProfile(
            id: "employee-2",
            name: "Jordan",
            email: "jordan@storepass.app",
            role: .employee,
            createdAt: Date(),
            lastLoginAt: Date(),
            provider: "manual.employee",
            assignedStoreIds: ["store-2"],
            isActive: true
        )

        let authService = MockDashboardAuthService(user: user)

        let store = Store(
            id: "store-2",
            name: "West Side",
            address: "99 Market St",
            latitude: 40.0,
            longitude: -73.0,
            radiusMeters: 200,
            isActive: true,
            managerId: "manager-2",
            createdAt: Date(),
            updatedAt: Date(),
            joinCode: "ZXCV5678",
            joinCodeCiphertext: "ZXCV5678",
            joinCodeLast4: "5678"
        )

        let storeRepository = MockStoreRepository()
        storeRepository.defaultStores = [store]
        storeRepository.storesByID[store.id] = store

        let checkInRepository = MockCheckInRepository()
        let locationService = MockLocationService()
        let checkInService = MockCheckInService()

        let firstRead = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.0001, longitude: -73.0001),
            altitude: 0,
            horizontalAccuracy: 8,
            verticalAccuracy: 8,
            timestamp: Date()
        )
        let secondRead = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 40.0002, longitude: -73.0002),
            altitude: 0,
            horizontalAccuracy: 6,
            verticalAccuracy: 6,
            timestamp: Date()
        )
        locationService.queuedLocations = [firstRead, secondRead, firstRead, secondRead]

        let viewModel = EmployeeDashboardViewModel(
            authService: authService,
            storeRepository: storeRepository,
            checkInService: checkInService,
            checkInRepository: checkInRepository,
            locationService: locationService,
            verifyReadDelayNanoseconds: 0
        )

        await viewModel.load()
        await viewModel.performAttendanceAction(.checkIn, photoData: Data([0x01]))

        XCTAssertEqual(checkInRepository.createCheckInCallCount, 1)
        XCTAssertNotNil(viewModel.activeSession)

        await viewModel.performAttendanceAction(.checkOut, photoData: Data([0x02]))

        XCTAssertEqual(checkInRepository.checkoutCallCount, 1)
        XCTAssertNil(viewModel.activeSession)
    }
}

@MainActor
private final class MockDashboardAuthService: AuthServiceProtocol {
    var currentUser: AppUser?
    var currentIdentity: AuthIdentity?

    init(user: AppUser?) {
        self.currentUser = user
        if let user {
            self.currentIdentity = AuthIdentity(userId: user.id, fullName: user.name, email: user.email, provider: user.provider)
        }
    }

    func setCurrentUser(_ user: AppUser?) {
        currentUser = user
    }

    func restoreSession(forceSignOutOnLaunch: Bool) async {
        if forceSignOutOnLaunch {
            currentUser = nil
            currentIdentity = nil
        }
    }

    func signInWithApple() async throws -> AppleSignInResult { throw CloudKitClientError.invalidData("not used") }
    func signInWithApple(authorizationResult: Result<ASAuthorization, Error>) throws -> AppleSignInResult { throw CloudKitClientError.invalidData("not used") }
    func signInManuallyAsEmployee(name: String, email: String) async throws -> ManualEmployeeSignInResult { throw CloudKitClientError.invalidData("not used") }
    func signUpEmployee(name: String, email: String, password: String) async throws -> EmployeeEmailSignInResult { throw CloudKitClientError.invalidData("not used") }
    func signInEmployee(email: String, password: String) async throws -> EmployeeEmailSignInResult { throw CloudKitClientError.invalidData("not used") }
    func authUser() -> AuthIdentity? { currentIdentity }
    func signOut() async throws {}
    func deleteAuthAccount() async throws {}
}

@MainActor
private final class MockStoreRepository: StoreRepositoryProtocol {
    var joinResult = JoinStoreResult(storeId: "", storeName: "", alreadyJoined: false, assignedStoreIds: [])
    var storesByID: [String: Store] = [:]
    var defaultStores: [Store] = []

    func fetchStores(ids: [String]?) async throws -> [Store] {
        if let ids {
            return ids.compactMap { storesByID[$0] }
        }
        return defaultStores
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        _ = managerId
        return []
    }

    func upsertStore(_ store: Store) async throws {
        storesByID[store.id] = store
    }

    func deleteStore(id: String) async throws {
        storesByID[id] = nil
    }

    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async throws -> StoreCreationResult {
        let store = Store(
            id: UUID().uuidString,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            isActive: true,
            managerId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            joinCode: "ABCD1234",
            joinCodeCiphertext: "ABCD1234",
            joinCodeLast4: "1234"
        )
        storesByID[store.id] = store
        return StoreCreationResult(store: store, joinCode: "ABCD1234")
    }

    func rotateStoreCode(storeId: String) async throws -> String {
        _ = storeId
        return "ABCD1234"
    }

    func getStoreJoinCode(storeId: String) async throws -> String {
        _ = storeId
        return "ABCD1234"
    }

    func joinStoreByCode(code: String) async throws -> JoinStoreResult {
        _ = code
        return joinResult
    }

    func leaveStore(storeId: String) async throws {
        _ = storeId
    }
}

@MainActor
private final class MockCheckInRepository: CheckInRepositoryProtocol {
    var sessions: [CheckIn] = []
    var createCheckInCallCount = 0
    var checkoutCallCount = 0

    @discardableResult
    func listenToTodaysCheckIns(
        filter: CheckInFilter,
        onUpdate: @escaping ([CheckIn]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> CheckInListenerToken {
        _ = filter
        _ = onError
        onUpdate(sessions)
        return MockCheckInListenerToken()
    }

    func createCheckIn(_ checkIn: CheckIn, checkInPhotoData: Data) async throws {
        _ = checkInPhotoData
        createCheckInCallCount += 1
        sessions.append(checkIn)
    }

    func checkout(
        checkinId: String,
        storeId: String,
        managerId: String?,
        checkoutLat: Double,
        checkoutLng: Double,
        distanceMeters: Double,
        accuracyMeters: Double,
        verification: Verify2ReadEvidence,
        checkOutPhotoData: Data
    ) async throws {
        _ = storeId
        _ = managerId
        _ = checkoutLat
        _ = checkoutLng
        _ = distanceMeters
        _ = accuracyMeters
        _ = verification
        _ = checkOutPhotoData
        checkoutCallCount += 1

        guard let index = sessions.firstIndex(where: { $0.id == checkinId }) else {
            throw CloudKitClientError.missingRecord("Check-in session not found.")
        }
        sessions[index].checkOutTime = Date()
    }

    func updateCheckIn(_ checkIn: CheckIn) async throws {
        if let index = sessions.firstIndex(where: { $0.id == checkIn.id }) {
            sessions[index] = checkIn
        }
    }

    func updateCheckInTimes(checkIn: CheckIn, newCheckInTime: Date, newCheckOutTime: Date?) async throws {
        _ = newCheckInTime
        _ = newCheckOutTime
        if let index = sessions.firstIndex(where: { $0.id == checkIn.id }) {
            sessions[index] = checkIn
        }
    }

    func deleteCheckIn(checkinId: String, employeeId: String, storeId: String, managerId: String?) async throws {
        _ = employeeId
        _ = storeId
        _ = managerId
        sessions.removeAll { $0.id == checkinId }
    }

    func deleteCheckIn(checkinId: String, storeId: String, managerId: String) async throws {
        _ = storeId
        _ = managerId
        sessions.removeAll { $0.id == checkinId }
    }

    func clearAllCheckIns(isManagerScope: Bool, storeId: String?, managerId: String?) async throws {
        _ = isManagerScope
        _ = storeId
        _ = managerId
        sessions.removeAll()
    }

    func clearAllCheckIns(storeId: String, managerId: String, limit: Int) async throws {
        _ = storeId
        _ = managerId
        _ = limit
        sessions.removeAll()
    }

    func fetchCheckIns(employeeId: String?, limit: Int) async throws -> [CheckIn] {
        let filtered = sessions.filter { session in
            guard let employeeId else { return true }
            return session.employeeId == employeeId
        }
        return Array(filtered.prefix(limit))
    }

    func fetchEmployeeCheckIns(employeeId: String, limit: Int) async throws -> [CheckIn] {
        Array(sessions.filter { $0.employeeId == employeeId }.prefix(limit))
    }

    func fetchManagerStoreCheckIns(managerId: String, storeId: String, fromDate: Date, toDate: Date, employeeId: String?, limit: Int) async throws -> [CheckIn] {
        _ = managerId
        _ = storeId
        _ = fromDate
        _ = toDate
        _ = employeeId
        return Array(sessions.prefix(limit))
    }

    func fetchTodaysCheckIns(filter: CheckInFilter) async throws -> [CheckIn] {
        _ = filter
        return sessions
    }
}

private final class MockCheckInListenerToken: CheckInListenerToken {
    func cancel() {}
}

private struct MockCheckInService: CheckInServiceProtocol {
    func evaluateLocation(for store: Store, user: UserProfile?) -> LocationCheckState {
        _ = store
        _ = user
        return .inRange(distance: 5)
    }

    func blockedReason(for state: LocationCheckState, user: UserProfile?, store: Store?) -> String? {
        _ = state
        _ = user
        _ = store
        return nil
    }
}

private final class MockLocationService: LocationServiceProtocol {
    var currentLocation: CLLocation?
    var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    var isPreciseLocationEnabled: Bool = true
    var lastErrorMessage: String?
    var queuedLocations: [CLLocation] = []

    func requestWhenInUseAuthorization() {}
    func requestLocation() {}

    func requestSingleAccurateLocation(timeoutSeconds: TimeInterval) async throws -> CLLocation {
        _ = timeoutSeconds
        if !queuedLocations.isEmpty {
            return queuedLocations.removeFirst()
        }
        return CLLocation(latitude: 40.0, longitude: -73.0)
    }

    func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }
}
