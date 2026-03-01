import CoreLocation
import Foundation

protocol LocationServiceProtocol: AnyObject {
    var currentLocation: CLLocation? { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var isPreciseLocationEnabled: Bool { get }
    var lastErrorMessage: String? { get }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func requestSingleAccurateLocation(timeoutSeconds: TimeInterval) async throws -> CLLocation
    func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double
}

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate, LocationServiceProtocol {
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastErrorMessage: String?

    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

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

        if let currentLocation, abs(currentLocation.timestamp.timeIntervalSinceNow) <= 5 {
            return currentLocation
        }

        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { continuation in
                    guard let self else {
                        continuation.resume(throwing: NSError(domain: "StorePass", code: 5302, userInfo: [NSLocalizedDescriptionKey: "Location service is unavailable."]))
                        return
                    }

                    if let existing = self.locationContinuation {
                        existing.resume(throwing: NSError(domain: "StorePass", code: 5303, userInfo: [NSLocalizedDescriptionKey: "Another location request is already in progress."]))
                    }

                    self.locationContinuation = continuation
                    self.manager.requestLocation()
                }
            }

            group.addTask {
                let nanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw NSError(domain: "StorePass", code: 5304, userInfo: [NSLocalizedDescriptionKey: "Location request timed out."])
            }

            guard let first = try await group.next() else {
                throw NSError(domain: "StorePass", code: 5305, userInfo: [NSLocalizedDescriptionKey: "Location could not be resolved."])
            }
            group.cancelAll()
            return first
        }
    }

    func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
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
        if let location = locations.last {
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain {
            lastErrorMessage = "We could not get your GPS position. Move to open sky and try again."
        } else {
            lastErrorMessage = error.localizedDescription
        }
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
}
