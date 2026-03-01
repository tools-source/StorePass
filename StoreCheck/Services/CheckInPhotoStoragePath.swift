import Foundation

enum CheckInPhotoStoragePath {
    static func makePath(storeId: String, employeeId: String, checkinId: String, kind: CheckInPhotoKind) -> String {
        "checkinPhotos/\(storeId)/\(employeeId)/\(checkinId)/\(kind.filename)"
    }

    static func shouldAttemptCheckoutDownload(for checkIn: CheckIn) -> Bool {
        guard checkIn.checkOutTime != nil else { return false }
        guard let path = checkIn.checkOutPhotoPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return false
        }
        return true
    }
}

