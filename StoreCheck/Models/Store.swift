import CoreLocation
import Foundation

struct Store: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var radiusMeters: Double
    var isActive: Bool
    var createdAt: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
