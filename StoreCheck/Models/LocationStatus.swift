import Foundation

enum LocationCheckState: Equatable {
    case unknown
    case permissionDenied
    case locationUnavailable
    case preciseLocationRequired
    case lowAccuracy(Double)
    case outOfRange(distance: Double)
    case inRange(distance: Double)
}
