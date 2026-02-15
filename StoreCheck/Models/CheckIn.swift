import Foundation

enum CheckInStatus: String, Codable, CaseIterable {
    case approved
    case rejected
}

struct CheckIn: Codable, Identifiable, Hashable {
    let id: String
    var employeeId: String
    var storeId: String
    var checkInTime: Date
    var clientLat: Double
    var clientLng: Double
    var distanceMeters: Double
    var accuracyMeters: Double
    var status: CheckInStatus
    var rejectReason: String?
    var employeeName: String
    var storeName: String
}
