import Foundation

struct DeviceInfo: Codable {
    var model: String
    var osVersion: String
}

enum CheckInStatus: String, Codable, CaseIterable {
    case approved
    case rejected
}

struct CheckIn: Codable, Identifiable {
    let id: String
    var employeeId: String
    var storeId: String
    var storeName: String
    var employeeName: String
    var checkInTime: Date
    var clientLat: Double
    var clientLng: Double
    var serverValidated: Bool
    var distanceMeters: Double
    var accuracyMeters: Double
    var deviceInfo: DeviceInfo?
    var status: CheckInStatus
    var rejectReason: String?
}

struct CheckInRequest {
    let employeeId: String
    let storeId: String
    let clientLat: Double
    let clientLng: Double
    let timestamp: Date
    let accuracyMeters: Double
    let deviceInfo: DeviceInfo
}
