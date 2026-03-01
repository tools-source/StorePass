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
    @Published var isVerificationInProgress = false

    private let authService: AuthService
    private let storeRepository: StoreRepositoryProtocol
    private let checkInService: CheckInServiceProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let locationService: LocationServiceProtocol

    // Tuning constants for geo-fence verification.
    private let verifyReadDelaySeconds: UInt64 = 7
    private let verifyAccuracyThresholdMeters: Double = 50
    private let verifyStrictDriftThresholdMeters: Double = 150
    private let verifyHighConfidenceAccuracyMeters: Double = 25
    private let verifyRelaxedDriftThresholdMeters: Double = 250

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
        case unstableLocation
        case locationUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Location permission is required before checking in."
            case .lowAccuracy:
                return "Location accuracy is too low. Move closer to a window and retry."
            case .outsideStore, .unstableLocation, .locationUnavailable:
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
        guard !isVerificationInProgress else { return }
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

        isVerificationInProgress = true
        defer { isVerificationInProgress = false }

        do {
            let verify = try await runTwoReadVerification(for: store)
            let approved = verify.status == "approved"
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
                verifyMethod: verify.method,
                verifyStatus: verify.status,
                verifyReason: verify.reason,
                verifyRead1Lat: verify.read1Lat,
                verifyRead1Lng: verify.read1Lng,
                verifyRead1Accuracy: verify.read1Accuracy,
                verifyRead1At: verify.read1At,
                verifyRead2Lat: verify.read2Lat,
                verifyRead2Lng: verify.read2Lng,
                verifyRead2Accuracy: verify.read2Accuracy,
                verifyRead2At: verify.read2At,
                verifyDistance1Meters: verify.distance1Meters,
                verifyDistance2Meters: verify.distance2Meters,
                verifyDriftMeters: verify.driftMeters,
                checkoutVerifyMethod: nil,
                checkoutVerifyStatus: nil,
                checkoutVerifyReason: nil,
                checkoutVerifyRead1Lat: nil,
                checkoutVerifyRead1Lng: nil,
                checkoutVerifyRead1Accuracy: nil,
                checkoutVerifyRead1At: nil,
                checkoutVerifyRead2Lat: nil,
                checkoutVerifyRead2Lng: nil,
                checkoutVerifyRead2Accuracy: nil,
                checkoutVerifyRead2At: nil,
                checkoutVerifyDistance1Meters: nil,
                checkoutVerifyDistance2Meters: nil,
                checkoutVerifyDriftMeters: nil
            )

            if approved {
                try await checkInRepository.createCheckIn(checkIn)
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
        guard !isVerificationInProgress else { return }
        guard let activeSession, let store = selectedStore else { return }
        refreshLocation()

        isVerificationInProgress = true
        defer { isVerificationInProgress = false }

        do {
            let verify = try await runTwoReadVerification(for: store)
            guard verify.status == "approved" else {
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

        try await Task.sleep(nanoseconds: verifyReadDelaySeconds * 1_000_000_000)

        let read2 = try await locationService.requestSingleAccurateLocation(timeoutSeconds: 8)
        print("[Verify2Read] step=read2 lat=\(read2.coordinate.latitude) lng=\(read2.coordinate.longitude) accuracy=\(read2.horizontalAccuracy)")

        let storeLocation = CLLocation(latitude: store.coordinate.latitude, longitude: store.coordinate.longitude)
        let distance1 = read1.distance(from: storeLocation)
        let distance2 = read2.distance(from: storeLocation)
        let drift = read2.distance(from: read1)

        let accuracy2 = read2.horizontalAccuracy
        let isInsideFence = distance2 <= Double(store.radiusMeters)
        let isAccurate = accuracy2 > 0 && accuracy2 <= verifyAccuracyThresholdMeters

        let driftLimit: Double
        if accuracy2 <= verifyHighConfidenceAccuracyMeters {
            driftLimit = verifyRelaxedDriftThresholdMeters
        } else {
            driftLimit = verifyStrictDriftThresholdMeters
        }
        let isDriftAcceptable = drift <= driftLimit

        print("[Verify2Read] step=computed distance1=\(distance1) distance2=\(distance2) drift=\(drift) accuracy1=\(read1.horizontalAccuracy) accuracy2=\(accuracy2) radius=\(store.radiusMeters)")

        if !isAccurate {
            print("[Verify2Read] step=rejected reason=low_accuracy")
            throw Verify2ReadError.lowAccuracy
        }
        if !isInsideFence {
            print("[Verify2Read] step=rejected reason=outside_fence")
            return Verify2ReadEvidence(method: "geo_2read_v1", status: "rejected", reason: Verify2ReadError.outsideStore.localizedDescription, read1Lat: read1.coordinate.latitude, read1Lng: read1.coordinate.longitude, read1Accuracy: read1.horizontalAccuracy, read1At: read1.timestamp, read2Lat: read2.coordinate.latitude, read2Lng: read2.coordinate.longitude, read2Accuracy: read2.horizontalAccuracy, read2At: read2.timestamp, distance1Meters: distance1, distance2Meters: distance2, driftMeters: drift)
        }
        if !isDriftAcceptable {
            print("[Verify2Read] step=rejected reason=unstable_location driftLimit=\(driftLimit)")
            return Verify2ReadEvidence(method: "geo_2read_v1", status: "rejected", reason: Verify2ReadError.unstableLocation.localizedDescription, read1Lat: read1.coordinate.latitude, read1Lng: read1.coordinate.longitude, read1Accuracy: read1.horizontalAccuracy, read1At: read1.timestamp, read2Lat: read2.coordinate.latitude, read2Lng: read2.coordinate.longitude, read2Accuracy: read2.horizontalAccuracy, read2At: read2.timestamp, distance1Meters: distance1, distance2Meters: distance2, driftMeters: drift)
        }

        print("[Verify2Read] step=accepted distance2=\(distance2) drift=\(drift) accuracy2=\(accuracy2)")
        return Verify2ReadEvidence(method: "geo_2read_v1", status: "approved", reason: nil, read1Lat: read1.coordinate.latitude, read1Lng: read1.coordinate.longitude, read1Accuracy: read1.horizontalAccuracy, read1At: read1.timestamp, read2Lat: read2.coordinate.latitude, read2Lng: read2.coordinate.longitude, read2Accuracy: read2.horizontalAccuracy, read2At: read2.timestamp, distance1Meters: distance1, distance2Meters: distance2, driftMeters: drift)
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
