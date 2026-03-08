import CoreLocation
import Foundation
import UserNotifications

@MainActor
final class EmployeeDashboardViewModel: ObservableObject {
    enum AttendanceAction {
        case checkIn
        case checkOut
    }

    struct SmartSuggestion: Identifiable, Equatable {
        enum Kind {
            case checkIn
            case checkOut
            case longShift
        }

        let id: String
        let kind: Kind
        let title: String
        let message: String
        let storeId: String
        let storeName: String
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
    @Published var todayTotalSeconds = 0
    @Published var weekTotalSeconds = 0
    @Published var monthTotalSeconds = 0
    @Published var smartSuggestion: SmartSuggestion?
    @Published var broadcastMessages: [BroadcastMessage] = []
    @Published var longShiftWarningText: String?
    @Published var notificationPermissionDenied = false

    private let authService: AuthServiceProtocol
    private let storeRepository: StoreRepositoryProtocol
    private let checkInService: CheckInServiceProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let locationService: LocationServiceProtocol

    private let verifyReadDelayNanoseconds: UInt64
    private let verifyAccuracyThresholdMeters: Double
    private let verifyReadTimeoutSeconds: TimeInterval
    private let verifyReadRetryCount: Int
    private let verifyCachedReadMaxAgeSeconds: TimeInterval

    private var allRecentCheckIns: [CheckIn] = []
    private var lastInsideStateByStoreId: [String: Bool] = [:]
    private var lastPromptAtByKey: [String: Date] = [:]
    private var didRequestNotificationAuthorization = false

    private let promptCooldownSeconds: TimeInterval = 8 * 60
    private let longShiftPromptCooldownSeconds: TimeInterval = 3 * 60 * 60

    private static let seenBroadcastKeyPrefix = "storecheck.seen.broadcasts.v2"

    init(
        authService: AuthServiceProtocol,
        storeRepository: StoreRepositoryProtocol,
        checkInService: CheckInServiceProtocol,
        checkInRepository: CheckInRepositoryProtocol,
        locationService: LocationServiceProtocol,
        verifyReadDelayNanoseconds: UInt64 = 1_500_000_000,
        verifyAccuracyThresholdMeters: Double = 65,
        verifyReadTimeoutSeconds: TimeInterval = 12,
        verifyReadRetryCount: Int = 1,
        verifyCachedReadMaxAgeSeconds: TimeInterval = 30
    ) {
        self.authService = authService
        self.storeRepository = storeRepository
        self.checkInService = checkInService
        self.checkInRepository = checkInRepository
        self.locationService = locationService
        self.verifyReadDelayNanoseconds = verifyReadDelayNanoseconds
        self.verifyAccuracyThresholdMeters = verifyAccuracyThresholdMeters
        self.verifyReadTimeoutSeconds = verifyReadTimeoutSeconds
        self.verifyReadRetryCount = max(0, verifyReadRetryCount)
        self.verifyCachedReadMaxAgeSeconds = max(1, verifyCachedReadMaxAgeSeconds)

        self.locationService.onStoreRegionEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleStoreRegionEvent(event)
            }
        }
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
        allRecentCheckIns.first(where: { $0.checkOutTime == nil })
    }

    var totalTodaySeconds: Int {
        todayTotalSeconds
    }

    var hasLongShiftWarning: Bool {
        longShiftWarningText != nil
    }

    var selectedStoreSupportsQRCode: Bool {
        guard let selectedStore else { return false }
        guard selectedStore.qrCheckInEnabled else { return false }
        return !(selectedStore.qrCodeToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func selectStore(withId storeId: String) {
        selectedStore = stores.first(where: { $0.id == storeId })
        configureSmartGeofenceMonitoring()
        refreshLocation()
        Task { await loadBroadcastMessages() }
        evaluateLongShiftWarningIfNeeded()
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

            configureSmartGeofenceMonitoring()
            refreshLocation()
            try await loadAttendanceAndSummaries()
            await loadBroadcastMessages()
            await refreshNotificationPermissionState()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            AppLog.error("Failed loading employee dashboard", error: error)
        }
    }

    func refreshLocation() {
        guard let selectedStore else {
            locationStatus = .unknown
            return
        }

        if selectedStore.radiusMeters <= 0 {
            locationStatus = .locationUnavailable
            errorMessage = "This store is missing a valid check-in radius. Contact your manager."
            return
        }

        lastLocationRefreshAt = Date()
        locationService.requestWhenInUseAuthorization()
        locationService.requestLocation()
        let nextStatus = checkInService.evaluateLocation(for: selectedStore, user: authService.currentUser)
        handleForegroundGeofenceTransition(for: selectedStore, status: nextStatus)
        locationStatus = nextStatus

        if let locationError = locationService.lastErrorMessage {
            errorMessage = locationError
        }
    }

    func performAttendanceAction(
        _ action: AttendanceAction,
        photoData: Data,
        checkInMethod: AttendanceMethod = .geofence
    ) async {
        switch action {
        case .checkIn:
            await runCheckInFlow(photoData: photoData, method: checkInMethod)
        case .checkOut:
            await runCheckOutFlow(photoData: photoData)
        }
    }

    func validateQRCodeForSelectedStore(scannedValue: String) async -> Bool {
        guard let user = authService.currentUser else {
            errorMessage = "Sign in required."
            return false
        }
        guard let selectedStore else {
            errorMessage = "Select a store first."
            return false
        }
        guard user.assignedStoreIds.contains(selectedStore.id) else {
            errorMessage = "You are not assigned to this store."
            return false
        }

        guard let payload = QRCheckInPayload.parse(scannedValue) else {
            errorMessage = "Invalid QR code. Ask your manager for a new store QR."
            return false
        }

        guard payload.storeId == selectedStore.id else {
            errorMessage = "This QR belongs to another store. Select the correct store and try again."
            return false
        }

        do {
            if let refreshedStore = try await storeRepository.fetchStores(ids: [selectedStore.id]).first {
                if let index = stores.firstIndex(where: { $0.id == refreshedStore.id }) {
                    stores[index] = refreshedStore
                }
                self.selectedStore = refreshedStore
            }
        } catch {
            AppLog.warning("QR validation fallback using cached store: \(AppLog.sanitize(error.localizedDescription))")
        }

        guard let latestStore = self.selectedStore else {
            errorMessage = "Store is unavailable."
            return false
        }

        guard latestStore.qrCheckInEnabled else {
            errorMessage = "QR check-in is currently disabled for this store."
            return false
        }

        guard let expectedToken = latestStore.qrCodeToken, !expectedToken.isEmpty else {
            errorMessage = "QR check-in is not configured for this store yet."
            return false
        }

        guard payload.token == expectedToken else {
            errorMessage = "This QR code is no longer valid. Ask your manager to refresh it."
            return false
        }

        errorMessage = nil
        return true
    }

    func confirmSmartSuggestion() -> AttendanceAction? {
        guard let smartSuggestion else { return nil }
        self.smartSuggestion = nil

        switch smartSuggestion.kind {
        case .checkIn:
            return activeSession == nil ? .checkIn : nil
        case .checkOut, .longShift:
            return activeSession != nil ? .checkOut : nil
        }
    }

    func dismissSmartSuggestion() {
        smartSuggestion = nil
    }

    func markBroadcastsRead() {
        guard let selectedStore, let user = authService.currentUser else { return }
        let ids = Set(broadcastMessages.map(\.id))
        persistSeenBroadcastIDs(ids, for: selectedStore.id, userId: user.id)
    }

    func refreshLiveStateTick() {
        evaluateLongShiftWarningIfNeeded()
    }

    private func runCheckInFlow(photoData: Data, method: AttendanceMethod) async {
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

        if method == .geofence {
            refreshLocation()
            if let blockedReason {
                errorMessage = blockedReason
                return
            }
        }

        isCheckInInProgress = true
        defer { isCheckInInProgress = false }

        do {
            let verify: Verify2ReadEvidence
            if method == .geofence {
                verify = try await runTwoReadVerification(for: store)
                guard verify.inside else {
                    throw Verify2ReadError.outsideStore
                }
            } else {
                verify = buildQRVerification(for: store)
            }

            let checkInTime = Date()
            let checkIn = CheckIn(
                id: UUID().uuidString,
                employeeId: user.id,
                storeId: store.id,
                checkInTime: checkInTime,
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
                checkInMethod: method,
                lateByMinutes: computeLateByMinutes(for: user, checkInTime: checkInTime, store: store),
                createdAt: Date(),
                updatedAt: Date()
            )

            try await checkInRepository.createCheckIn(checkIn, checkInPhotoData: photoData)
            checkInSuccessBanner = true
            try await loadAttendanceAndSummaries()
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
        guard let store = stores.first(where: { $0.id == activeSession.storeId }) ?? selectedStore else {
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

            try await loadAttendanceAndSummaries()
        } catch {
            errorMessage = error.localizedDescription
            AppLog.error("Check-out flow failed", error: error)
        }
    }

    private func runTwoReadVerification(for store: Store) async throws -> Verify2ReadEvidence {
        locationService.requestWhenInUseAuthorization()
        if locationService.authorizationStatus == .notDetermined {
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        let authorization = locationService.authorizationStatus
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            throw Verify2ReadError.permissionDenied
        }

        let read1 = try await requestVerificationRead(label: "read1")
        try await Task.sleep(nanoseconds: verifyReadDelayNanoseconds)
        let read2 = try await requestVerificationRead(label: "read2")

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

    private func requestVerificationRead(label: String) async throws -> CLLocation {
        var attempts = 0
        while true {
            locationService.requestLocation()
            do {
                return try await locationService.requestSingleAccurateLocation(timeoutSeconds: verifyReadTimeoutSeconds)
            } catch {
                if isLocationTimeout(error),
                   let cached = locationService.currentLocation,
                   cached.horizontalAccuracy > 0,
                   cached.horizontalAccuracy <= verifyAccuracyThresholdMeters,
                   abs(cached.timestamp.timeIntervalSinceNow) <= verifyCachedReadMaxAgeSeconds {
                    AppLog.warning(
                        "Using cached GPS for \(label) after timeout accuracy=\(Int(cached.horizontalAccuracy)) ageSeconds=\(Int(abs(cached.timestamp.timeIntervalSinceNow)))"
                    )
                    return cached
                }

                guard isLocationTimeout(error), attempts < verifyReadRetryCount else {
                    if isLocationTimeout(error) {
                        throw CloudKitClientError.invalidData(
                            "Location request timed out. Move near a window or outdoors, keep Wi-Fi enabled, then retry."
                        )
                    }
                    throw error
                }

                attempts += 1
                AppLog.warning("Location \(label) timed out; retrying attempt=\(attempts + 1)")
            }
        }
    }

    private func isLocationTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "StorePass", nsError.code == 5304 {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    private func loadAttendanceAndSummaries() async throws {
        guard let user = authService.currentUser else { return }
        let history = try await checkInRepository.fetchEmployeeCheckIns(employeeId: user.id, limit: 2_000)
        allRecentCheckIns = history.sorted { $0.checkInTime > $1.checkInTime }

        let calendar = calendarForSummaryCalculations()
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now

        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now)
        let monthInterval = calendar.dateInterval(of: .month, for: now)

        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        todayTotalSeconds = workedSeconds(in: dayInterval, from: allRecentCheckIns)
        if let weekInterval {
            weekTotalSeconds = workedSeconds(in: weekInterval, from: allRecentCheckIns)
        } else {
            weekTotalSeconds = 0
        }
        if let monthInterval {
            monthTotalSeconds = workedSeconds(in: monthInterval, from: allRecentCheckIns)
        } else {
            monthTotalSeconds = 0
        }

        todaysCheckIns = allRecentCheckIns.filter { overlapSeconds(in: dayInterval, for: $0) > 0 }
        evaluateLongShiftWarningIfNeeded()
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
            configureSmartGeofenceMonitoring()
            refreshLocation()
            await loadBroadcastMessages()
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
            configureSmartGeofenceMonitoring()
        } catch {
            errorMessage = error.localizedDescription
            AppLog.error("Failed leaving store", error: error)
        }
    }

    private func buildQRVerification(for store: Store) -> Verify2ReadEvidence {
        let now = Date()
        let fallbackCoordinate = store.coordinate
        let currentLocation = locationService.currentLocation
        let coordinate = currentLocation?.coordinate ?? fallbackCoordinate
        let accuracy = max(currentLocation?.horizontalAccuracy ?? Double(store.radiusMeters), 1)
        let measuredDistance = locationService.distance(from: coordinate, to: store.coordinate)

        return Verify2ReadEvidence(
            method: "qr_v1",
            version: 2,
            inside: true,
            reason: "QR verified",
            read1Lat: coordinate.latitude,
            read1Lng: coordinate.longitude,
            read1Accuracy: accuracy,
            read1At: now,
            read2Lat: coordinate.latitude,
            read2Lng: coordinate.longitude,
            read2Accuracy: accuracy,
            read2At: now,
            distance1Meters: measuredDistance,
            distance2Meters: measuredDistance,
            driftMeters: 0
        )
    }

    private func computeLateByMinutes(for user: UserProfile, checkInTime: Date, store: Store) -> Int? {
        guard let expectedStartMinutes = user.expectedStartMinutesFromMidnight else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = store.resolvedTimeZone

        let dayStart = calendar.startOfDay(for: checkInTime)
        guard let expectedStartTime = calendar.date(byAdding: .minute, value: expectedStartMinutes, to: dayStart) else {
            return nil
        }

        let lateMinutes = Int(checkInTime.timeIntervalSince(expectedStartTime) / 60)
        return lateMinutes > 0 ? lateMinutes : 0
    }

    private func calendarForSummaryCalculations() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = selectedStore?.resolvedTimeZone ?? .current
        return calendar
    }

    private func workedSeconds(in interval: DateInterval, from checkIns: [CheckIn]) -> Int {
        checkIns.reduce(0) { partial, item in
            guard item.status == .approved else { return partial }
            return partial + overlapSeconds(in: interval, for: item)
        }
    }

    private func overlapSeconds(in interval: DateInterval, for checkIn: CheckIn) -> Int {
        let shiftStart = checkIn.checkInTime
        let shiftEnd = checkIn.checkOutTime ?? Date()
        guard shiftEnd > shiftStart else { return 0 }

        let start = max(interval.start, shiftStart)
        let end = min(interval.end, shiftEnd)
        guard end > start else { return 0 }
        return Int(end.timeIntervalSince(start))
    }

    private func configureSmartGeofenceMonitoring() {
        guard let selectedStore,
              let user = authService.currentUser,
              user.assignedStoreIds.contains(selectedStore.id) else {
            locationService.stopMonitoringStoreRegion()
            return
        }
        locationService.startMonitoringStoreRegion(selectedStore)
    }

    private func handleForegroundGeofenceTransition(for store: Store, status: LocationCheckState) {
        guard let user = authService.currentUser,
              user.assignedStoreIds.contains(store.id) else {
            return
        }

        guard status.isRangeDetermined else {
            return
        }

        let isInside = status.isInRange
        let previous = lastInsideStateByStoreId[store.id]
        lastInsideStateByStoreId[store.id] = isInside

        guard let previous, previous != isInside else {
            return
        }

        if isInside, activeSession == nil {
            suggestCheckIn(for: store)
        } else if !isInside,
                  let activeSession,
                  activeSession.storeId == store.id {
            suggestCheckOut(for: store)
        }
    }

    private func handleStoreRegionEvent(_ event: StoreRegionEvent) {
        guard let user = authService.currentUser,
              user.assignedStoreIds.contains(event.storeId) else {
            return
        }

        guard let store = stores.first(where: { $0.id == event.storeId }) else {
            return
        }

        switch event.transition {
        case .entered:
            if activeSession == nil {
                suggestCheckIn(for: store)
            }
        case .exited:
            if let activeSession, activeSession.storeId == store.id {
                suggestCheckOut(for: store)
            }
        }
    }

    private func suggestCheckIn(for store: Store) {
        let key = "suggest.checkin.\(store.id)"
        guard shouldFirePrompt(for: key, cooldown: promptCooldownSeconds) else { return }
        presentSmartSuggestion(
            kind: .checkIn,
            title: "Near \(store.name)",
            message: "You are near \(store.name). Check in?",
            store: store
        )
        postLocalNotification(
            identifier: "checkin_\(store.id)",
            title: "Check-in reminder",
            body: "You are near \(store.name). Check in?"
        )
    }

    private func suggestCheckOut(for store: Store) {
        let key = "suggest.checkout.\(store.id)"
        guard shouldFirePrompt(for: key, cooldown: promptCooldownSeconds) else { return }
        presentSmartSuggestion(
            kind: .checkOut,
            title: "Left \(store.name)",
            message: "It looks like you left \(store.name). Check out?",
            store: store
        )
        postLocalNotification(
            identifier: "checkout_\(store.id)",
            title: "Check-out reminder",
            body: "It looks like you left \(store.name). Check out?"
        )
    }

    private func evaluateLongShiftWarningIfNeeded() {
        longShiftWarningText = nil

        guard let activeSession,
              let store = stores.first(where: { $0.id == activeSession.storeId }) ?? selectedStore else {
            return
        }

        let thresholdHours = max(store.longShiftWarningHours, 1)
        let thresholdSeconds = thresholdHours * 3600
        let elapsedSeconds = max(Int(Date().timeIntervalSince(activeSession.checkInTime)), 0)
        guard elapsedSeconds >= thresholdSeconds else {
            return
        }

        longShiftWarningText = "You have been checked in for \(DurationFormatter.clockString(from: elapsedSeconds))."

        let key = "suggest.longshift.\(activeSession.id)"
        guard shouldFirePrompt(for: key, cooldown: longShiftPromptCooldownSeconds) else {
            return
        }

        presentSmartSuggestion(
            kind: .longShift,
            title: "Long shift detected",
            message: "You have been on shift for over \(thresholdHours) hours. Consider checking out when finished.",
            store: store
        )
        postLocalNotification(
            identifier: "longshift_\(activeSession.id)",
            title: "Long shift reminder",
            body: "You've been checked in for over \(thresholdHours) hours."
        )
    }

    private func shouldFirePrompt(for key: String, cooldown: TimeInterval) -> Bool {
        let now = Date()
        if let lastDate = lastPromptAtByKey[key], now.timeIntervalSince(lastDate) < cooldown {
            return false
        }
        lastPromptAtByKey[key] = now
        return true
    }

    private func presentSmartSuggestion(kind: SmartSuggestion.Kind, title: String, message: String, store: Store) {
        smartSuggestion = SmartSuggestion(
            id: "\(kind)-\(store.id)-\(Int(Date().timeIntervalSince1970))",
            kind: kind,
            title: title,
            message: message,
            storeId: store.id,
            storeName: store.name
        )
    }

    private func loadBroadcastMessages() async {
        guard let selectedStore else {
            broadcastMessages = []
            return
        }

        do {
            let messages = try await storeRepository.fetchBroadcastMessages(storeId: selectedStore.id, limit: 40)
            broadcastMessages = messages

            guard let user = authService.currentUser else { return }
            let seen = seenBroadcastIDs(for: selectedStore.id, userId: user.id)
            let unseen = messages.filter { !seen.contains($0.id) }
            guard !unseen.isEmpty else { return }

            if let latest = unseen.first {
                postLocalNotification(
                    identifier: "broadcast_\(latest.id)",
                    title: "\(selectedStore.name) broadcast",
                    body: latest.message
                )
            }

            persistSeenBroadcastIDs(Set(unseen.map(\.id)), for: selectedStore.id, userId: user.id)
        } catch {
            AppLog.warning("Failed loading broadcasts: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func seenBroadcastIDs(for storeId: String, userId: String) -> Set<String> {
        let key = "\(Self.seenBroadcastKeyPrefix).\(userId).\(storeId)"
        let values = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(values)
    }

    private func persistSeenBroadcastIDs(_ ids: Set<String>, for storeId: String, userId: String) {
        let key = "\(Self.seenBroadcastKeyPrefix).\(userId).\(storeId)"
        var merged = seenBroadcastIDs(for: storeId, userId: userId)
        merged.formUnion(ids)
        UserDefaults.standard.set(Array(merged), forKey: key)
    }

    private func refreshNotificationPermissionState() async {
        let center = UNUserNotificationCenter.current()
        let settings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
        notificationPermissionDenied = settings.authorizationStatus == .denied
    }

    private func postLocalNotification(identifier: String, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await withCheckedContinuation { continuation in
                center.getNotificationSettings { settings in
                    continuation.resume(returning: settings)
                }
            }

            var isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            if !isAuthorized,
               settings.authorizationStatus == .notDetermined,
               !didRequestNotificationAuthorization {
                didRequestNotificationAuthorization = true
                isAuthorized = await withCheckedContinuation { continuation in
                    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        continuation.resume(returning: granted)
                    }
                }
            }

            await MainActor.run {
                self.notificationPermissionDenied = !isAuthorized && settings.authorizationStatus == .denied
            }

            guard isAuthorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { _ in }
        }
    }
}

private struct QRCheckInPayload {
    let storeId: String
    let token: String

    static func parse(_ rawValue: String) -> QRCheckInPayload? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           let host = components.host,
           (components.scheme?.lowercased() == "storepass" || components.scheme?.lowercased() == "storecheck"),
           host.lowercased() == "checkin" {
            let items = components.queryItems ?? []
            let storeId = items.first(where: { $0.name == "storeId" })?.value
            let token = items.first(where: { $0.name == "token" })?.value
            if let storeId, let token, !storeId.isEmpty, !token.isEmpty {
                return QRCheckInPayload(storeId: storeId, token: token)
            }
        }

        let components = trimmed.split(separator: "|").map(String.init)
        if components.count == 3,
           components[0].lowercased() == "storepass",
           !components[1].isEmpty,
           !components[2].isEmpty {
            return QRCheckInPayload(storeId: components[1], token: components[2])
        }

        return nil
    }
}

private extension LocationCheckState {
    var isInRange: Bool {
        if case .inRange = self { return true }
        return false
    }

    var isRangeDetermined: Bool {
        switch self {
        case .inRange, .outOfRange:
            return true
        default:
            return false
        }
    }
}
