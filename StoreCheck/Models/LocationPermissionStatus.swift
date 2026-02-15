import CoreLocation
import Foundation

enum LocationPermissionStatus: Equatable {
    case notDetermined
    case authorizedWhenInUse(precise: Bool)
    case authorizedAlways(precise: Bool)
    case denied
    case restricted

    init(status: CLAuthorizationStatus, preciseEnabled: Bool) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .authorizedWhenInUse:
            self = .authorizedWhenInUse(precise: preciseEnabled)
        case .authorizedAlways:
            self = .authorizedAlways(precise: preciseEnabled)
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .notDetermined
        }
    }

    var title: String {
        switch self {
        case .notDetermined:
            return "Not Determined"
        case .authorizedWhenInUse(let precise):
            return precise ? "When In Use · Precise On" : "When In Use · Precise Off"
        case .authorizedAlways(let precise):
            return precise ? "Always · Precise On" : "Always · Precise Off"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        }
    }

    var detail: String {
        switch self {
        case .notDetermined:
            return "Location is needed to validate check-ins."
        case .authorizedWhenInUse(let precise), .authorizedAlways(let precise):
            return precise ? "You're ready to check in." : "Enable Precise Location for reliable check-ins."
        case .denied, .restricted:
            return "Enable location in Settings to use geo check-in."
        }
    }
}
