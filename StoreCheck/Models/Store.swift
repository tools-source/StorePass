import CoreLocation
import Foundation

struct Store: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Int
    var isActive: Bool
    var managerId: String?
    var createdAt: Date?
    var updatedAt: Date?
    var joinCodeLast4: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct StoreMember: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let role: UserRole
    let joinedAt: Date
    let isActive: Bool
    let addedBy: String
}
