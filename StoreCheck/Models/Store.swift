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
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var qrCheckInEnabled: Bool = false
    var qrCodeToken: String?
    var longShiftWarningHours: Int = 10

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

    var resolvedTimeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
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

enum AttendanceMethod: String, Codable, CaseIterable {
    case geofence
    case qr
}

enum StoreActivityEventKind: String, Codable {
    case checkedIn
    case checkedOut
    case employeeJoined
    case employeeRemoved
    case storeCreated
    case storeUpdated
    case broadcastSent
}

struct StoreActivityEvent: Identifiable, Hashable, Codable {
    let id: String
    let storeId: String
    let storeName: String
    let employeeId: String?
    let employeeName: String?
    let employeeEmail: String?
    let kind: StoreActivityEventKind
    let occurredAt: Date
    let checkInId: String?

    var subtitle: String {
        switch kind {
        case .checkedIn:
            return "Checked in"
        case .checkedOut:
            return "Checked out"
        case .employeeJoined:
            return "Joined store"
        case .employeeRemoved:
            return "Removed from store"
        case .storeCreated:
            return "Store created"
        case .storeUpdated:
            return "Store updated"
        case .broadcastSent:
            return "Broadcast sent"
        }
    }
}

struct BroadcastMessage: Identifiable, Hashable, Codable {
    let id: String
    let storeId: String
    let storeName: String
    let managerUserId: String
    let managerName: String
    let message: String
    let createdAt: Date
}
