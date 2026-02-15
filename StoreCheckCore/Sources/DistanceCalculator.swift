import Foundation

public struct DistanceCalculator {
    public init() {}

    public func haversineMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = pow(sin(dLat / 2), 2) + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * pow(sin(dLng / 2), 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
