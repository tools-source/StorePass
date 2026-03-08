import Foundation

struct Verify2ReadEvidence: Codable, Hashable {
    let method: String
    let version: Int
    let inside: Bool
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
    var verifyVersion: Int?
    var verifyMethod: String?
    var verifyInInside: Bool?
    var verifyInDistance1Meters: Double?
    var verifyInDistance2Meters: Double?
    var verifyInDriftMeters: Double?
    var verifyInRead1At: Date?
    var verifyInRead2At: Date?
    var verifyInAccuracy1Meters: Double?
    var verifyInAccuracy2Meters: Double?
    var verifyOutInside: Bool?
    var verifyOutDistance1Meters: Double?
    var verifyOutDistance2Meters: Double?
    var verifyOutDriftMeters: Double?
    var verifyOutRead1At: Date?
    var verifyOutRead2At: Date?
    var verifyOutAccuracy1Meters: Double?
    var verifyOutAccuracy2Meters: Double?
    var checkInPhotoAssetID: String?
    var checkOutPhotoAssetID: String?
    var checkInMethod: AttendanceMethod? = .geofence
    var lateByMinutes: Int?
    var createdAt: Date?
    var updatedAt: Date?

    var computedDurationSeconds: Int? {
        if let durationSeconds {
            return durationSeconds
        }
        guard let checkOutTime else { return nil }
        return max(Int(checkOutTime.timeIntervalSince(checkInTime)), 0)
    }

    var isCheckInVerifiedInside: Bool {
        verifyInInside == true
    }

    var isCheckOutVerifiedInside: Bool {
        verifyOutInside == true
    }

    var hasVerificationPhoto: Bool {
        checkInPhotoAssetID != nil || checkOutPhotoAssetID != nil
    }

    var verificationPhotoPath: String? {
        checkInPhotoAssetID
    }

    var checkOutVerificationPhotoPath: String? {
        checkOutPhotoAssetID
    }

    var verificationPhotoCapturedAt: Date? {
        checkInTime
    }

    var isLateArrival: Bool {
        (lateByMinutes ?? 0) > 0
    }
}

enum VerificationPhotoKind: String, Codable, CaseIterable, Identifiable {
    case checkIn
    case checkOut

    var id: String { rawValue }
}
