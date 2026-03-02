import CoreLocation
import Foundation

@MainActor
final class EmployeeDashboardViewModel: ObservableObject {
    @Published var stores: [Store] = []
    @Published var selectedStore: Store?
    @Published var locationStatus: LocationCheckState = .unknown
    @Published var errorMessage: String?
    @Published var checkInSuccessBanner = false
    @Published var joinCodeInput = ""
    @Published var joinStatusMessage: String?
    @Published var todaysCheckIns: [CheckIn] = []
    @Published var lastLocationRefreshAt: Date?
    @Published var isCheckInInProgress = false
    @Published var isCheckOutInProgress = false

    private let authService: AuthService
    private let storeRepository: StoreRepositoryProtocol
    private let checkInService: CheckInServiceProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let locationService: LocationServiceProtocol

    // Tuning constants for geo-fence verification.
    private let verifyReadDelayNanoseconds: UInt64 = 2_000_000_000
    private let verifyAccuracyThresholdMeters: Double = 65

    init(
        authService: AuthService,
        storeRepository: StoreRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        locationService: LocationServiceProtocol
    ) {
        self.authService = authService
        self.storeRepository = storeRepository
        self.checkInService = checkInService
        self.checkInRepository = checkInRepository
        self.locationService = locationService
    }

    private enum Verify2ReadError: LocalizedError {
        case permissionDenied
        case lowAccuracy
        case outsideStore
        case locationUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Location permission is required before checking in."
            case .lowAccuracy:
                return "Location accuracy is too low. Move closer to a window and retry."
            case .outsideStore, .locationUnavailable:
                return "We couldn’t confirm you’re inside the store. Try again near the entrance."
            }
        }
    }

    var blockedReason: String? {
        checkInService.blockedReason(for: locationStatus, user: authService.currentUser, store: selectedStore)
    }

    var activeSession: CheckIn? {
        todaysCheckIns.first(where: { $0.checkOutTime == nil })
    }

    func selectStore(withId storeId: String) {
        Task { @MainActor in
            selectedStore = stores.first(where: { $0.id == storeId })
            refreshLocation()
        }
    }

    func load() async {
        guard let user = authService.currentUser else { return }
        do {
            stores = try await storeRepository.fetchStores(ids: user.assignedStoreIds)
            if let currentSelection = selectedStore, stores.contains(where: { $0.id == currentSelection.id }) {
                selectedStore = currentSelection
            } else {
                selectedStore = stores.first
            }
            refreshLocation()
            try await loadTodaySessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLocation() {
        guard let selectedStore else { return }
        lastLocationRefreshAt = Date()
        locationService.requestWhenInUseAuthorization()
        locationService.requestLocation()
        locationStatus = checkInService.evaluateLocation(for: selectedStore, user: authService.currentUser)
        if let locationError = locationService.lastErrorMessage {
            errorMessage = locationError
        }
    }

    func beginCheckIn() {
        Task {
            await runCheckInFlow()
        }
    }

    func beginCheckOut() {
        Task {
            await runCheckOutFlow()
        }
    }

    private func runCheckInFlow() async {
        guard !isCheckInInProgress else { return }
        guard let user = authService.currentUser else {
            errorMessage = "Sign in required."
            return
        }
        guard let store = selectedStore else {
            errorMessage = "No assigned store available."
            return
        }
        refreshLocation()
        guard blockedReason == nil else {
            errorMessage = blockedReason
            return
        }

        isCheckInInProgress = true
        defer { isCheckInInProgress = false }

        do {
            let verify = try await runTwoReadVerification(for: store)
            let approved = verify.inside
            let checkIn = CheckIn(
                id: UUID().uuidString,
                employeeId: user.id,
                storeId: store.id,
                checkInTime: Date(),
                checkOutTime: nil,
                clientLat: verify.read2Lat,
                clientLng: verify.read2Lng,
                distanceMeters: verify.distance2Meters,
                accuracyMeters: verify.read2Accuracy,
                checkOutLat: nil,
                checkOutLng: nil,
                checkOutDistanceMeters: nil,
                checkOutAccuracyMeters: nil,
                durationSeconds: nil,
                status: approved ? .approved : .rejected,
                rejectReason: approved ? nil : verify.reason,
                employeeName: user.name,
                employeeEmail: user.email,
                storeName: store.name,
                verifyVersion: verify.version,
                verifyMethod: verify.method,
                verifyInInside: verify.inside,
                verifyInDistance1Meters: verify.distance1Meters,
                verifyInDistance2Meters: verify.distance2Meters,
                verifyInDriftMeters: verify.driftMeters,
                verifyInRead1At: verify.read1At,
                verifyInRead2At: verify.read2At,
                verifyInAccuracy1Meters: verify.read1Accuracy,
                verifyInAccuracy2Meters: verify.read2Accuracy,
                verifyOutInside: nil,
                verifyOutDistance1Meters: nil,
                verifyOutDistance2Meters: nil,
                verifyOutDriftMeters: nil,
                verifyOutRead1At: nil,
                verifyOutRead2At: nil,
                verifyOutAccuracy1Meters: nil,
                verifyOutAccuracy2Meters: nil
            )

            try await checkInRepository.createCheckIn(checkIn)
            if approved {
                checkInSuccessBanner = true
            } else {
                errorMessage = verify.reason ?? Verify2ReadError.outsideStore.localizedDescription
            }

            try await loadTodaySessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runCheckOutFlow() async {
        guard !isCheckOutInProgress else { return }
        guard let activeSession, let store = selectedStore else { return }
        refreshLocation()

        isCheckOutInProgress = true
        defer { isCheckOutInProgress = false }

        do {
            let verify = try await runTwoReadVerification(for: store)
            guard verify.inside else {
                errorMessage = verify.reason ?? Verify2ReadError.outsideStore.localizedDescription
                return
            }

            try await checkInRepository.checkout(
                checkinId: activeSession.id,
                storeId: store.id,
                managerId: nil,
                checkoutLat: verify.read2Lat,
                checkoutLng: verify.read2Lng,
                distanceMeters: verify.distance2Meters,
                accuracyMeters: verify.read2Accuracy,
                verification: verify
            )
            try await loadTodaySessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runTwoReadVerification(for store: Store) async throws -> Verify2ReadEvidence {
        locationService.requestWhenInUseAuthorization()
        let auth = locationService.authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else {
            throw Verify2ReadError.permissionDenied
        }

        let read1 = try await locationService.requestSingleAccurateLocation(timeoutSeconds: 8)
        print("[Verify2Read] step=read1 lat=\(read1.coordinate.latitude) lng=\(read1.coordinate.longitude) accuracy=\(read1.horizontalAccuracy)")

        try await Task.sleep(nanoseconds: verifyReadDelayNanoseconds)

        let read2 = try await locationService.requestSingleAccurateLocation(timeoutSeconds: 8)
        print("[Verify2Read] step=read2 lat=\(read2.coordinate.latitude) lng=\(read2.coordinate.longitude) accuracy=\(read2.horizontalAccuracy)")

        let storeLocation = CLLocation(latitude: store.coordinate.latitude, longitude: store.coordinate.longitude)
        let distance1 = read1.distance(from: storeLocation)
        let distance2 = read2.distance(from: storeLocation)
        let drift = read2.distance(from: read1)

        let accuracy2 = read2.horizontalAccuracy
        let isInsideFence = distance2 <= Double(store.radiusMeters)
        let isAccurate = accuracy2 > 0 && accuracy2 <= verifyAccuracyThresholdMeters
        let reason: String?
        if !isAccurate {
            reason = "Low accuracy"
        } else if !isInsideFence {
            reason = "Out of range"
        } else {
            reason = nil
        }

        return Verify2ReadEvidence(
            method: "gps_v2",
            version: 2,
            inside: reason == nil,
            reason: reason,
            read1Lat: read1.coordinate.latitude,
            read1Lng: read1.coordinate.longitude,
            read1Accuracy: read1.horizontalAccuracy,
            read1At: read1.timestamp,
            read2Lat: read2.coordinate.latitude,
            read2Lng: read2.coordinate.longitude,
            read2Accuracy: read2.horizontalAccuracy,
            read2At: read2.timestamp,
            distance1Meters: distance1,
            distance2Meters: distance2,
            driftMeters: drift
        )
    }

    private func loadTodaySessions() async throws {
        guard let user = authService.currentUser else { return }
        let history = try await checkInRepository.fetchEmployeeCheckIns(employeeId: user.id, limit: 30)
        let today = Calendar.current.startOfDay(for: Date())
        todaysCheckIns = history.filter { Calendar.current.isDate($0.checkInTime, inSameDayAs: today) }
    }

    func joinStoreByCode() async {
        do {
            errorMessage = nil
            let result = try await storeRepository.joinStoreByCode(code: joinCodeInput)

            if var currentUser = authService.currentUser {
                currentUser.assignedStoreIds = result.assignedStoreIds
                authService.setCurrentUser(currentUser)
            }

            let joinedStore = try await storeRepository.fetchStores(ids: [result.storeId]).first
            if let joinedStore, stores.contains(where: { $0.id == joinedStore.id }) == false {
                stores.append(joinedStore)
                stores.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            selectedStore = selectedStore ?? joinedStore
            refreshLocation()
            joinStatusMessage = result.alreadyJoined
                ? "You're already linked to \(result.storeName)."
                : "Joined \(result.storeName) successfully."
            joinCodeInput = ""
        } catch {
            joinStatusMessage = nil
            errorMessage = error.localizedDescription
            print("[Stores] Join-by-code error: \(error.localizedDescription)")
        }
    }

    func leaveStore(storeId: String) async {
        do {
            try await storeRepository.leaveStore(storeId: storeId)
            if var currentUser = authService.currentUser {
                currentUser.assignedStoreIds.removeAll { $0 == storeId }
                authService.setCurrentUser(currentUser)
            }
            await load()
            if stores.isEmpty {
                selectedStore = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
