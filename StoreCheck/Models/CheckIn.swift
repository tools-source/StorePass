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
    var checkOutTime: Date?
    var clientLat: Double
    var clientLng: Double
    var distanceMeters: Double
    var accuracyMeters: Double
    var checkOutLat: Double?
    var checkOutLng: Double?
    var checkOutDistanceMeters: Double?
    var checkOutAccuracyMeters: Double?
    var durationSeconds: Int?
    var status: CheckInStatus
    var rejectReason: String?
    var employeeName: String
    var employeeEmail: String?
    var storeName: String

    var computedDurationSeconds: Int? {
        guard let checkOutTime else { return nil }
        if let durationSeconds {
            return durationSeconds
        }
        return max(Int(checkOutTime.timeIntervalSince(checkInTime)), 0)
    }
}
