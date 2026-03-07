import CoreLocation
import Foundation

@MainActor
final class EmployeeDashboardViewModel: ObservableObject {
    enum AttendanceAction {
        case checkIn
        case checkOut
    }

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

    private let verifyReadDelayNanoseconds: UInt64 = 1_500_000_000
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

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Location permission is required before checking in."
            case .lowAccuracy:
                return "Location accuracy is too low. Move to a clear area and retry."
            case .outsideStore:
                return "You must be inside the store geo-fence to continue."
            }
        }
    }

    var blockedReason: String? {
        checkInService.blockedReason(for: locationStatus, user: authService.currentUser, store: selectedStore)
    }

    var activeSession: CheckIn? {
        todaysCheckIns.first(where: { $0.checkOutTime == nil })
    }

    var totalTodaySeconds: Int {
        todaysCheckIns.compactMap(\.computedDurationSeconds).reduce(0, +)
    }

    func selectStore(withId storeId: String) {
        selectedStore = stores.first(where: { $0.id == storeId })
        refreshLocation()
    }

    func load() async {
        guard let user = authService.currentUser else { return }

        do {
            let preferredStoreIds = user.assignedStoreIds.isEmpty ? nil : user.assignedStoreIds
            stores = try await storeRepository.fetchStores(ids: preferredStoreIds)
            if let current = selectedStore, stores.contains(where: { $0.id == current.id }) {
                selectedStore = current
            } else {
                selectedStore = stores.first
            }

            refreshLocation()
            try await loadTodaySessions()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            AppLog.error("Failed loading employee dashboard", error: error)
        }
    }

    func refreshLocation() {
        guard let selectedStore else { return }

        if selectedStore.radiusMeters <= 0 {
            locationStatus = .locationUnavailable
            errorMessage = "This store is missing a valid check-in radius. Contact your manager."
            return
        }

        lastLocationRefreshAt = Date()
        locationService.requestWhenInUseAuthorization()
        locationService.requestLocation()
        locationStatus = checkInService.evaluateLocation(for: selectedStore, user: authService.currentUser)

        if let locationError = locationService.lastErrorMessage {
            errorMessage = locationError
        }
    }

    func performAttendanceAction(_ action: AttendanceAction, photoData: Data) async {
        switch action {
        case .checkIn:
            await runCheckInFlow(photoData: photoData)
        case .checkOut:
            await runCheckOutFlow(photoData: photoData)
        }
    }

    private func runCheckInFlow(photoData: Data) async {
        guard !isCheckInInProgress else { return }
        guard let user = authService.currentUser else {
            errorMessage = "Sign in required."
            return
        }
        guard let store = selectedStore else {
            errorMessage = "No assigned store available."
            return
        }
        guard !photoData.isEmpty else {
            errorMessage = "A front camera photo is required to check in."
            return
        }

        refreshLocation()
        if let blockedReason {
            errorMessage = blockedReason
            return
        }

        isCheckInInProgress = true
        defer { isCheckInInProgress = false }

        do {
            let verify = try await runTwoReadVerification(for: store)
            guard verify.inside else {
                throw Verify2ReadError.outsideStore
            }

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
                status: .approved,
                rejectReason: nil,
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
                verifyOutAccuracy2Meters: nil,
                checkInPhotoAssetID: nil,
                checkOutPhotoAssetID: nil,
                createdAt: Date(),
                updatedAt: Date()
            )

            try await checkInRepository.createCheckIn(checkIn, checkInPhotoData: photoData)
            checkInSuccessBanner = true
            try await loadTodaySessions()
        } catch {
            errorMessage = error.localizedDescription
            AppLog.error("Check-in flow failed", error: error)
        }
    }

    private func runCheckOutFlow(photoData: Data) async {
        guard !isCheckOutInProgress else { return }
        guard let activeSession else {
            errorMessage = "You don't have an active check-in session."
            return
        }
        guard let store = selectedStore else {
            errorMessage = "No assigned store available."
            return
        }
        guard !photoData.isEmpty else {
            errorMessage = "A front camera photo is required to check out."
            return
        }

        refreshLocation()

        isCheckOutInProgress = true
        defer { isCheckOutInProgress = false }

        do {
            let verify = try await runTwoReadVerification(for: store)
            guard verify.inside else {
                throw Verify2ReadError.outsideStore
            }

            try await checkInRepository.checkout(
                checkinId: activeSession.id,
                storeId: store.id,
                managerId: store.managerId,
                checkoutLat: verify.read2Lat,
                checkoutLng: verify.read2Lng,
                distanceMeters: verify.distance2Meters,
                accuracyMeters: verify.read2Accuracy,
                verification: verify,
                checkOutPhotoData: photoData
            )

            try await loadTodaySessions()
        } catch {
            errorMessage = error.localizedDescription
            AppLog.error("Check-out flow failed", error: error)
        }
    }

    private func runTwoReadVerification(for store: Store) async throws -> Verify2ReadEvidence {
        locationService.requestWhenInUseAuthorization()
        let authorization = locationService.authorizationStatus
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            throw Verify2ReadError.permissionDenied
        }

        let read1 = try await locationService.requestSingleAccurateLocation(timeoutSeconds: 8)
        try await Task.sleep(nanoseconds: verifyReadDelayNanoseconds)
        let read2 = try await locationService.requestSingleAccurateLocation(timeoutSeconds: 8)

        let storeLocation = CLLocation(latitude: store.coordinate.latitude, longitude: store.coordinate.longitude)
        let distance1 = read1.distance(from: storeLocation)
        let distance2 = read2.distance(from: storeLocation)
        let drift = read2.distance(from: read1)

        let accuracy2 = read2.horizontalAccuracy
        let isAccurate = accuracy2 > 0 && accuracy2 <= verifyAccuracyThresholdMeters
        guard isAccurate else {
            throw Verify2ReadError.lowAccuracy
        }

        let isInside = distance2 <= Double(store.radiusMeters)

        return Verify2ReadEvidence(
            method: "gps_v2",
            version: 2,
            inside: isInside,
            reason: isInside ? nil : "Out of range",
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
        let history = try await checkInRepository.fetchEmployeeCheckIns(employeeId: user.id, limit: 60)
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

            if let joinedStore = try await storeRepository.fetchStores(ids: [result.storeId]).first,
               !stores.contains(where: { $0.id == joinedStore.id }) {
                stores.append(joinedStore)
                stores.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }

            selectedStore = selectedStore ?? stores.first(where: { $0.id == result.storeId })
            refreshLocation()
            joinStatusMessage = result.alreadyJoined ? "You are already linked to \(result.storeName)." : "Joined \(result.storeName)."
            joinCodeInput = ""
        } catch {
            joinStatusMessage = nil
            errorMessage = error.localizedDescription
            AppLog.error("Failed joining store", error: error)
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
            AppLog.error("Failed leaving store", error: error)
        }
    }
}
