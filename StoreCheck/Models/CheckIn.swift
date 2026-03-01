import Foundation


struct Verify2ReadEvidence: Codable, Hashable {
    let method: String
    let status: String
    let reason: String?
    let read1Lat: Double
    let read1Lng: Double
    let read1Accuracy: Double
    let read1At: Date
    let read2Lat: Double
    let read2Lng: Double
    let read2Accuracy: Double
    let read2At: Date
    let distance1Meters: Double
    let distance2Meters: Double
    let driftMeters: Double
}

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
    var verifyMethod: String?
    var verifyStatus: String?
    var verifyReason: String?
    var verifyRead1Lat: Double?
    var verifyRead1Lng: Double?
    var verifyRead1Accuracy: Double?
    var verifyRead1At: Date?
    var verifyRead2Lat: Double?
    var verifyRead2Lng: Double?
    var verifyRead2Accuracy: Double?
    var verifyRead2At: Date?
    var verifyDistance1Meters: Double?
    var verifyDistance2Meters: Double?
    var verifyDriftMeters: Double?
    var checkoutVerifyMethod: String?
    var checkoutVerifyStatus: String?
    var checkoutVerifyReason: String?
    var checkoutVerifyRead1Lat: Double?
    var checkoutVerifyRead1Lng: Double?
    var checkoutVerifyRead1Accuracy: Double?
    var checkoutVerifyRead1At: Date?
    var checkoutVerifyRead2Lat: Double?
    var checkoutVerifyRead2Lng: Double?
    var checkoutVerifyRead2Accuracy: Double?
    var checkoutVerifyRead2At: Date?
    var checkoutVerifyDistance1Meters: Double?
    var checkoutVerifyDistance2Meters: Double?
    var checkoutVerifyDriftMeters: Double?

    var computedDurationSeconds: Int? {
        guard let checkOutTime else { return nil }
        if let durationSeconds {
            return durationSeconds
        }
        return max(Int(checkOutTime.timeIntervalSince(checkInTime)), 0)
    }

    var isCheckInVerifiedInside: Bool {
        verifyStatus == "approved"
    }

    var isCheckOutVerifiedInside: Bool {
        checkoutVerifyStatus == "approved"
    }
}
