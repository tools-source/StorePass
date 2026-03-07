import CoreLocation
import Foundation

protocol CheckInServiceProtocol {
    func evaluateLocation(for store: Store, user: UserProfile?) -> LocationCheckState
    func blockedReason(for state: LocationCheckState, user: UserProfile?, store: Store?) -> String?
}

final class CheckInService: CheckInServiceProtocol {
    private let locationService: LocationServiceProtocol
    private let maxAccuracyMeters: Double = 100

    init(locationService: LocationServiceProtocol) {
        self.locationService = locationService
    }

    func evaluateLocation(for store: Store, user: UserProfile?) -> LocationCheckState {
        guard let user else { return .unknown }
        guard user.isActive else { return .permissionDenied }

        let auth = locationService.authorizationStatus
        guard auth == .authorizedWhenInUse || auth == .authorizedAlways else { return .permissionDenied }
        guard locationService.isPreciseLocationEnabled else { return .preciseLocationRequired }
        guard let location = locationService.currentLocation else { return .locationUnavailable }
        guard location.horizontalAccuracy > 0 && location.horizontalAccuracy <= maxAccuracyMeters else {
            return .lowAccuracy(location.horizontalAccuracy)
        }

        let distance = locationService.distance(from: location.coordinate, to: store.coordinate)
        return distance <= Double(store.radiusMeters) ? .inRange(distance: distance) : .outOfRange(distance: distance)
    }

    func blockedReason(for state: LocationCheckState, user: UserProfile?, store: Store?) -> String? {
        guard let user else { return "Sign in required." }
        guard user.isActive else { return "Your account is inactive. Contact your manager." }
        guard let store else { return "No assigned store is available." }

        switch state {
        case .inRange:
            return nil
        case .outOfRange:
            return "You must be inside \(store.radiusMeters)m of \(store.name)."
        case .permissionDenied:
            return "Enable location permission in Settings to continue."
        case .locationUnavailable:
            return "Current location is unavailable. Move outdoors and refresh."
        case .preciseLocationRequired:
            return "Turn on Precise Location for reliable attendance verification."
        case .lowAccuracy(let accuracy):
            return "Current GPS accuracy is ±\(Int(accuracy))m. Move to a clearer area and retry."
        case .unknown:
            return "Checking your current location..."
        }
    }
}
