import CoreLocation
import Foundation

enum StoreRegionTransition: String {
    case entered
    case exited
}

struct StoreRegionEvent: Equatable {
    let storeId: String
    let storeName: String
    let transition: StoreRegionTransition
    let occurredAt: Date
}

protocol LocationServiceProtocol: AnyObject {
    var currentLocation: CLLocation? { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var isPreciseLocationEnabled: Bool { get }
    var lastErrorMessage: String? { get }
    var onStoreRegionEvent: ((StoreRegionEvent) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func requestSingleAccurateLocation(timeoutSeconds: TimeInterval) async throws -> CLLocation
    func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double
    func startMonitoringStoreRegion(_ store: Store)
    func stopMonitoringStoreRegion()
}

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate, LocationServiceProtocol {
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastErrorMessage: String?
    var onStoreRegionEvent: ((StoreRegionEvent) -> Void)?

    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var monitoredStore: Store?
    private var lastRegionTransitionAtByKey: [String: Date] = [:]
    private let regionTransitionThrottleSeconds: TimeInterval = 240

    var isPreciseLocationEnabled: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        authorizationStatus = manager.authorizationStatus
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestLocation() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            lastErrorMessage = "Location permission is required before checking in."
            return
        }
        manager.requestLocation()
    }

    func requestSingleAccurateLocation(timeoutSeconds: TimeInterval = 8) async throws -> CLLocation {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            throw NSError(domain: "StorePass", code: 5301, userInfo: [NSLocalizedDescriptionKey: "Location permission is required before checking in."])
        }

        if let currentLocation, abs(currentLocation.timestamp.timeIntervalSinceNow) <= 12 {
            return currentLocation
        }

        return try await withCheckedThrowingContinuation { continuation in
            if let existing = locationContinuation {
                existing.resume(throwing: NSError(domain: "StorePass", code: 5303, userInfo: [NSLocalizedDescriptionKey: "Another location request is already in progress."]))
            }

            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil

            locationContinuation = continuation
            manager.requestLocation()

            let timeout = DispatchWorkItem { [weak self] in
                guard let self, let pending = self.locationContinuation else { return }
                pending.resume(throwing: NSError(domain: "StorePass", code: 5304, userInfo: [NSLocalizedDescriptionKey: "Location request timed out."]))
                self.locationContinuation = nil
                self.lastErrorMessage = "Location request timed out."
            }
            timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        }
    }

    func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    func startMonitoringStoreRegion(_ store: Store) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            return
        }

        if authorizationStatus == .notDetermined {
            manager.requestAlwaysAuthorization()
        } else if authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }

        stopMonitoringStoreRegion()
        monitoredStore = store

        let radius = min(max(Double(store.radiusMeters), 50), 1_000)
        let region = CLCircularRegion(center: store.coordinate, radius: radius, identifier: storeRegionIdentifier(for: store.id))
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        manager.requestState(for: region)
    }

    func stopMonitoringStoreRegion() {
        for region in manager.monitoredRegions where region.identifier.hasPrefix("storepass.store.") {
            manager.stopMonitoring(for: region)
        }
        monitoredStore = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
        lastErrorMessage = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let location = locations.last {
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain {
            lastErrorMessage = "We could not get your GPS position. Move to open sky and try again."
        } else {
            lastErrorMessage = error.localizedDescription
        }
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        emitRegionEventIfNeeded(for: region, transition: .entered)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        emitRegionEventIfNeeded(for: region, transition: .exited)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        // Priming region state prevents immediate duplicate prompts on first monitor start.
        let key = region.identifier
        switch state {
        case .inside:
            lastRegionTransitionAtByKey["\(key):inside"] = Date()
        case .outside:
            lastRegionTransitionAtByKey["\(key):outside"] = Date()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func storeRegionIdentifier(for storeId: String) -> String {
        "storepass.store.\(storeId)"
    }

    private func emitRegionEventIfNeeded(for region: CLRegion, transition: StoreRegionTransition) {
        guard let store = monitoredStore else { return }
        guard region.identifier == storeRegionIdentifier(for: store.id) else { return }

        let now = Date()
        let key = "\(region.identifier):\(transition.rawValue)"
        if let previous = lastRegionTransitionAtByKey[key],
           now.timeIntervalSince(previous) < regionTransitionThrottleSeconds {
            return
        }
        lastRegionTransitionAtByKey[key] = now

        onStoreRegionEvent?(
            StoreRegionEvent(
                storeId: store.id,
                storeName: store.name,
                transition: transition,
                occurredAt: now
            )
        )
    }
}
