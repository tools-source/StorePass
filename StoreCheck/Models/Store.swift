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
    var joinCode: String?
    var joinCodeCiphertext: String?
    var joinCodeLast4: String?

    var resolvedJoinCode: String? {
        let trimmedJoinCode = joinCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedJoinCode, !trimmedJoinCode.isEmpty {
            return trimmedJoinCode
        }

        let trimmedCiphertext = joinCodeCiphertext?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedCiphertext, !trimmedCiphertext.isEmpty {
            return trimmedCiphertext
        }

        let trimmedLast4 = joinCodeLast4?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedLast4, !trimmedLast4.isEmpty {
            return trimmedLast4
        }

        return nil
    }

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
