import FirebaseFirestore
import Foundation

struct CheckInFilter {
    var storeId: String?
    var status: CheckInStatus?
    var date: Date = Date()
}

protocol CheckInRepositoryProtocol {
    func createCheckIn(_ checkIn: CheckIn) async throws
    func fetchCheckIns(employeeId: String?, limit: Int) async throws -> [CheckIn]
    func fetchTodaysCheckIns(filter: CheckInFilter) async throws -> [CheckIn]
}

final class FirestoreCheckInRepository: CheckInRepositoryProtocol {
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreCheckInRepository.db")
        return Firestore.firestore()
    }

    func createCheckIn(_ checkIn: CheckIn) async throws {
        do {
            try await db.collection("checkins").document(checkIn.id).setData(encode(checkIn: checkIn))
        } catch {
            throw mapFirestoreError(error)
        }
    }

    func fetchCheckIns(employeeId: String? = nil, limit: Int = 30) async throws -> [CheckIn] {
        do {
            var query: Query = db.collection("checkins").order(by: "checkInTime", descending: true).limit(to: limit)
            if let employeeId {
                query = query.whereField("employeeId", isEqualTo: employeeId)
            }
            let snap = try await query.getDocuments()
            return snap.documents.compactMap(decodeCheckIn)
        } catch {
            throw mapFirestoreError(error)
        }
    }

    func fetchTodaysCheckIns(filter: CheckInFilter) async throws -> [CheckIn] {
        let start = Calendar.current.startOfDay(for: filter.date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date()

        do {
            var query: Query = db.collection("checkins")
                .whereField("checkInTime", isGreaterThanOrEqualTo: Timestamp(date: start))
                .whereField("checkInTime", isLessThan: Timestamp(date: end))

            if let storeId = filter.storeId, !storeId.isEmpty {
                query = query.whereField("storeId", isEqualTo: storeId)
            }

            if let status = filter.status {
                query = query.whereField("status", isEqualTo: status.rawValue)
            }

            let snapshot = try await query.order(by: "checkInTime", descending: true).getDocuments()
            return snapshot.documents.compactMap(decodeCheckIn)
        } catch {
            throw mapFirestoreError(error)
        }
    }

    private func encode(checkIn: CheckIn) -> [String: Any] {
        [
            "employeeId": checkIn.employeeId,
            "storeId": checkIn.storeId,
            "checkInTime": Timestamp(date: checkIn.checkInTime),
            "clientLat": checkIn.clientLat,
            "clientLng": checkIn.clientLng,
            "distanceMeters": checkIn.distanceMeters,
            "accuracyMeters": checkIn.accuracyMeters,
            "status": checkIn.status.rawValue,
            "rejectReason": checkIn.rejectReason as Any,
            "employeeName": checkIn.employeeName,
            "storeName": checkIn.storeName
        ]
    }

    private func decodeCheckIn(document: QueryDocumentSnapshot) -> CheckIn? {
        let data = document.data()
        guard let employeeId = data["employeeId"] as? String,
              let storeId = data["storeId"] as? String,
              let checkInTime = (data["checkInTime"] as? Timestamp)?.dateValue() else {
            return nil
        }

        return CheckIn(
            id: document.documentID,
            employeeId: employeeId,
            storeId: storeId,
            checkInTime: checkInTime,
            clientLat: data["clientLat"] as? Double ?? 0,
            clientLng: data["clientLng"] as? Double ?? 0,
            distanceMeters: data["distanceMeters"] as? Double ?? 0,
            accuracyMeters: data["accuracyMeters"] as? Double ?? 0,
            status: CheckInStatus(rawValue: data["status"] as? String ?? "rejected") ?? .rejected,
            rejectReason: data["rejectReason"] as? String,
            employeeName: data["employeeName"] as? String ?? "Employee",
            storeName: data["storeName"] as? String ?? "Store"
        )
    }

    private func mapFirestoreError(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              nsError.code == FirestoreErrorCode.permissionDenied.rawValue else {
            return error
        }

        return NSError(
            domain: "StorePass",
            code: nsError.code,
            userInfo: [NSLocalizedDescriptionKey: "You don't have permission for this action."]
        )
    }
}
