import FirebaseFirestore
import Foundation

struct CheckInFilter {
    var storeId: String?
    var status: CheckInStatus?
    var date: Date = Date()
}

protocol CheckInRepositoryProtocol {
    @discardableResult
    func listenToTodaysCheckIns(
        filter: CheckInFilter,
        onUpdate: @escaping ([CheckIn]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> CheckInListenerToken

    func createCheckIn(_ checkIn: CheckIn) async throws
    func fetchCheckIns(employeeId: String?, limit: Int) async throws -> [CheckIn]
    func fetchTodaysCheckIns(filter: CheckInFilter) async throws -> [CheckIn]
}

protocol CheckInListenerToken {
    func cancel()
}

private final class FirestoreCheckInListenerToken: CheckInListenerToken {
    private var registration: ListenerRegistration?

    init(registration: ListenerRegistration) {
        self.registration = registration
    }

    func cancel() {
        registration?.remove()
        registration = nil
    }
}

final class FirestoreCheckInRepository: CheckInRepositoryProtocol {
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreCheckInRepository.db")
        return Firestore.firestore()
    }

    @discardableResult
    func listenToTodaysCheckIns(
        filter: CheckInFilter,
        onUpdate: @escaping ([CheckIn]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> CheckInListenerToken {
        let query = todaysCheckinsQuery(for: filter)
        let registration = query.addSnapshotListener { [weak self] snapshot, error in
            if let error {
                onError(self?.mapFirestoreError(error) ?? error)
                return
            }

            guard let snapshot else {
                onError(NSError(domain: "StorePass", code: 5005, userInfo: [NSLocalizedDescriptionKey: "No check-in data was returned."]))
                return
            }

            onUpdate(snapshot.documents.compactMap { self?.decodeCheckIn(document: $0) })
        }

        return FirestoreCheckInListenerToken(registration: registration)
    }

    func createCheckIn(_ checkIn: CheckIn) async throws {
        let payload = encode(checkIn: checkIn)
        print("[CheckIn] write payload storeId=\(checkIn.storeId) employeeId=\(checkIn.employeeId) lat=\(checkIn.clientLat) lng=\(checkIn.clientLng) distance=\(checkIn.distanceMeters) accuracy=\(checkIn.accuracyMeters)")

        do {
            try await db.collection("checkins").document(checkIn.id).setData(payload)
        } catch {
            logFirestoreError(prefix: "[CheckIn] createCheckIn", error: error)
            throw mapFirestoreError(error)
        }
    }

    func fetchCheckIns(employeeId: String? = nil, limit: Int = 30) async throws -> [CheckIn] {
        do {
            var query: Query = db.collection("checkins")
                .order(by: "checkInTime", descending: true)
                .limit(to: limit)

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
        do {
            let snapshot = try await todaysCheckinsQuery(for: filter).getDocuments()
            return snapshot.documents.compactMap(decodeCheckIn)
        } catch {
            throw mapFirestoreError(error)
        }
    }

    private func todaysCheckinsQuery(for filter: CheckInFilter) -> Query {
        let start = Calendar.current.startOfDay(for: filter.date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date()

        var query: Query = db.collection("checkins")
            .whereField("checkInTime", isGreaterThanOrEqualTo: Timestamp(date: start))
            .whereField("checkInTime", isLessThan: Timestamp(date: end))

        if let storeId = filter.storeId, !storeId.isEmpty {
            query = query.whereField("storeId", isEqualTo: storeId)
        }

        if let status = filter.status {
            query = query.whereField("status", isEqualTo: status.rawValue)
        }

        return query.order(by: "checkInTime", descending: true)
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

        // Only map permission denied into a friendly app error
        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code),
           code == .permissionDenied {
            return NSError(
                domain: "StorePass",
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "You don't have permission for this action."]
            )
        }

        return error
    }

    private func logFirestoreError(prefix: String, error: Error) {
        let nsError = error as NSError
        print("\(prefix) error domain=\(nsError.domain) code=\(nsError.code)")
        print("\(prefix) userInfo=\(nsError.userInfo)")

        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            print("\(prefix) firestoreCode=\(code)")
        }
    }
}
