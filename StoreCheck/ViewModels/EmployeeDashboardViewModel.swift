import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import UserNotifications

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

    private let authService: AuthService
    private let storeRepository: StoreRepositoryProtocol
    private let checkInService: CheckInServiceProtocol
    private let checkInRepository: CheckInRepositoryProtocol
    private let locationService: LocationServiceProtocol

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
            await EmployeeGeofenceNotificationManager.shared.refreshMonitoredStores(stores)
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

    func checkIn() async {
        guard let user = authService.currentUser, let store = selectedStore else { return }
        do {
            _ = try await checkInService.submitCheckIn(user: user, store: store)
            checkInSuccessBanner = true
            try await loadTodaySessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkOut() async {
        guard let activeSession, let store = selectedStore else { return }
        guard let location = locationService.currentLocation else {
            errorMessage = "Location unavailable."
            return
        }

        do {
            let distance = locationService.distance(from: location.coordinate, to: store.coordinate)
            try await checkInRepository.checkout(
                checkinId: activeSession.id,
                storeId: store.id,
                managerId: nil,
                checkoutLat: location.coordinate.latitude,
                checkoutLng: location.coordinate.longitude,
                distanceMeters: distance,
                accuracyMeters: location.horizontalAccuracy
            )
            try await loadTodaySessions()
        } catch {
            errorMessage = error.localizedDescription
        }
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
            await EmployeeGeofenceNotificationManager.shared.refreshMonitoredStores(stores)
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

struct EmployeeNotificationPrefs: Equatable {
    var remindersEnabled = true
    var checkInEnabled = true
    var checkOutEnabled = true
    var radiusMeters: Double = 150
    var quietHoursEnabled = false
    var quietStartHour = 22
    var quietEndHour = 7

    init() {}

    init?(data: [String: Any]) {
        remindersEnabled = data["remindersEnabled"] as? Bool ?? true
        checkInEnabled = data["checkInEnabled"] as? Bool ?? true
        checkOutEnabled = data["checkOutEnabled"] as? Bool ?? true
        radiusMeters = min(max(data["radiusMeters"] as? Double ?? 150, 50), 1000)
        quietHoursEnabled = data["quietHoursEnabled"] as? Bool ?? false
        quietStartHour = min(max(data["quietStartHour"] as? Int ?? 22, 0), 23)
        quietEndHour = min(max(data["quietEndHour"] as? Int ?? 7, 0), 23)
    }

    var firestorePayload: [String: Any] {
        [
            "remindersEnabled": remindersEnabled,
            "checkInEnabled": checkInEnabled,
            "checkOutEnabled": checkOutEnabled,
            "radiusMeters": radiusMeters,
            "quietHoursEnabled": quietHoursEnabled,
            "quietStartHour": quietStartHour,
            "quietEndHour": quietEndHour,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
    }
}

final class EmployeeGeofenceNotificationManager: NSObject, CLLocationManagerDelegate {
    static let shared = EmployeeGeofenceNotificationManager()

    private let locationManager = CLLocationManager()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let firestore = Firestore.firestore()
    private let cooldownSeconds: TimeInterval = 10 * 60

    private var storesById: [String: Store] = [:]
    private var lastEventAt: [String: Date] = [:]
    private var prefs = EmployeeNotificationPrefs()

    var currentPrefs: EmployeeNotificationPrefs { prefs }

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true // Needed for geofence entry/exit callbacks in background.
        Task { await loadPrefs() }
    }

    func loadPrefs() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let snap = try await firestore.collection("users").document(uid).collection("notificationPrefs").document("employeeLocal").getDocument()
            if let data = snap.data(), let decoded = EmployeeNotificationPrefs(data: data) {
                prefs = decoded
            }
        } catch {
            print("[EmployeeNotifications] loadPrefs failed: \(error.localizedDescription)")
        }
    }

    func savePrefs(_ prefs: EmployeeNotificationPrefs) async {
        self.prefs = prefs
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            try await firestore.collection("users").document(uid).collection("notificationPrefs").document("employeeLocal").setData(prefs.firestorePayload, merge: true)
        } catch {
            print("[EmployeeNotifications] savePrefs failed: \(error.localizedDescription)")
        }
        await refreshMonitoredStores(Array(storesById.values))
    }

    func requestPermissions() {
        notificationCenter.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        locationManager.requestAlwaysAuthorization()
    }

    func refreshMonitoredStores(_ stores: [Store]) async {
        storesById = Dictionary(uniqueKeysWithValues: stores.map { ($0.id, $0) })
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }

        guard prefs.remindersEnabled else { return }

        requestPermissions()

        for store in stores.prefix(20) {
            let radius = min(max(prefs.radiusMeters, 50), 1000)
            let region = CLCircularRegion(center: store.coordinate, radius: radius, identifier: store.id)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            locationManager.startMonitoring(for: region)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        trigger(region: region, type: .enter)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        trigger(region: region, type: .exit)
    }

    private enum EventType { case enter, exit }

    private func trigger(region: CLRegion, type: EventType) {
        guard prefs.remindersEnabled else { return }
        if type == .enter && !prefs.checkInEnabled { return }
        if type == .exit && !prefs.checkOutEnabled { return }
        if prefs.quietHoursEnabled && isQuietHoursNow() { return }

        let key = "\(region.identifier)-\(type == .enter ? "enter" : "exit")"
        if let lastAt = lastEventAt[key], Date().timeIntervalSince(lastAt) < cooldownSeconds {
            return
        }
        lastEventAt[key] = Date()

        let storeName = storesById[region.identifier]?.name ?? "your store"
        let content = UNMutableNotificationContent()
        content.title = type == .enter ? "Reminder to Check In" : "Reminder to Check Out"
        content.body = type == .enter
            ? "You're near \(storeName). Reminder: Check in."
            : "You left \(storeName). Reminder: Check out."
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        notificationCenter.add(request)
    }

    private func isQuietHoursNow() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        if prefs.quietStartHour == prefs.quietEndHour { return true }
        if prefs.quietStartHour < prefs.quietEndHour {
            return hour >= prefs.quietStartHour && hour < prefs.quietEndHour
        }
        return hour >= prefs.quietStartHour || hour < prefs.quietEndHour
    }
}
