import FirebaseAuth
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
    func fetchEmployeeCheckIns(employeeId: String, limit: Int) async throws -> [CheckIn]
    func fetchManagerStoreCheckIns(managerId: String, storeId: String, limit: Int) async throws -> [CheckIn]
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
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
        }

        guard checkIn.employeeId == uid else {
            throw NSError(domain: "StorePass", code: 4008, userInfo: [NSLocalizedDescriptionKey: "Check-in employeeId must match the signed-in user."])
        }

        guard !checkIn.storeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "StorePass", code: 4009, userInfo: [NSLocalizedDescriptionKey: "A valid storeId is required for check-in."])
        }

        let storeSnapshot: DocumentSnapshot
        do {
            storeSnapshot = try await db.collection("stores").document(checkIn.storeId).getDocument()
        } catch {
            logFirestoreError(prefix: "[CheckIn][READ] storeForMirror", error: error)
            throw mapFirestoreError(error)
        }

        guard let storeData = storeSnapshot.data(),
              let managerId = storeData["managerId"] as? String,
              !managerId.isEmpty else {
            throw NSError(domain: "StorePass", code: 4010, userInfo: [NSLocalizedDescriptionKey: "Store manager could not be resolved for this check-in."])
        }

        let payload = encode(checkIn: checkIn, storeData: storeData)
        let rootPath = "checkins/\(checkIn.id)"
        let employeeMirrorPath = "employeeCheckins/\(checkIn.employeeId)/checkins/\(checkIn.id)"
        let managerMirrorPath = "managerCheckins/\(managerId)/stores/\(checkIn.storeId)/checkins/\(checkIn.id)"

        print("[CheckIn][WRITE] managerId=\(managerId) rootPath=\(rootPath)")
        print("[CheckIn][WRITE] employeeMirrorPath=\(employeeMirrorPath)")
        print("[CheckIn][WRITE] managerMirrorPath=\(managerMirrorPath)")
        print("[CheckIn][WRITE] payloadKeys=\(payload.keys.sorted())")
        print("[CheckIn][WRITE] payload employeeId=\(String(describing: payload["employeeId"])) storeId=\(String(describing: payload["storeId"]))")
        print("[CheckIn][WRITE] payload checkInTime=\(String(describing: payload["checkInTime"])) createdAt=\(String(describing: payload["createdAt"]))")
        print("[CheckIn][WRITE] payload lat=\(String(describing: payload["latitude"])) lng=\(String(describing: payload["longitude"]))")
        print("[CheckIn][WRITE] create semantics: setData without merge on root /checkins/{id}")

        do {
            let batch = db.batch()
            batch.setData(payload, forDocument: db.collection("checkins").document(checkIn.id))
            batch.setData(payload, forDocument: db.collection("employeeCheckins").document(checkIn.employeeId).collection("checkins").document(checkIn.id))
            batch.setData(payload, forDocument: db.collection("managerCheckins").document(managerId).collection("stores").document(checkIn.storeId).collection("checkins").document(checkIn.id))

            try await batch.commit()
            print("[CheckIn][WRITE] batchCommitSuccess checkinId=\(checkIn.id)")
        } catch {
            logFirestoreError(prefix: "[CheckIn] createCheckIn", error: error)
            FirestorePermissionLogger.log(operation: "setData", path: "checkins/\(checkIn.id)", error: error, uid: uid)
            throw mapFirestoreError(error)
        }
    }

    func fetchCheckIns(employeeId: String? = nil, limit: Int = 30) async throws -> [CheckIn] {
        // Debugging notes:
        // - Expected query shape: /checkins where employeeId == <uid> orderBy(checkInTime desc) limit(<N>)
        // - Required composite index (if missing): employeeId ASC + checkInTime DESC on collection checkins
        do {
            var query: Query = db.collection("checkins").limit(to: limit)
            var filterSummary = "none"

            if let employeeId {
                query = query.whereField("employeeId", isEqualTo: employeeId)
                filterSummary = "employeeId == \(employeeId)"
            }

            query = query.order(by: "checkInTime", descending: true)

            print("[CheckIn][QUERY] employeeHistory uid=\(employeeId ?? "nil") collection=checkins filters=[\(filterSummary)] orderBy=[checkInTime DESC] limit=\(limit)")
            print("[CheckIn][QUERY] indexHint=checkins(employeeId ASC, checkInTime DESC)")

            let snap = try await query.getDocuments()
            let decoded = snap.documents.compactMap(decodeCheckIn)
            let first = decoded.first?.checkInTime.description ?? "nil"
            let last = decoded.last?.checkInTime.description ?? "nil"
            print("[CheckIn][QUERY] employeeHistory resultCount=\(decoded.count) firstCheckInTime=\(first) lastCheckInTime=\(last)")
            return decoded
        } catch {
            logFirestoreError(prefix: "[CheckIn][QUERY] employeeHistory", error: error)
            throw mapFirestoreError(error)
        }
    }

    func fetchEmployeeCheckIns(employeeId: String, limit: Int = 30) async throws -> [CheckIn] {
        let path = "employeeCheckins/\(employeeId)/checkins"
        print("[CheckIn][QUERY] employeeMirror path=\(path) uid=\(employeeId) orderBy=checkInTime DESC limit=\(limit)")

        do {
            let snapshot = try await db.collection("employeeCheckins")
                .document(employeeId)
                .collection("checkins")
                .order(by: "checkInTime", descending: true)
                .limit(to: limit)
                .getDocuments()

            let decoded = snapshot.documents.compactMap(decodeCheckIn)
            print("[CheckIn][QUERY] employeeMirror uid=\(employeeId) count=\(decoded.count)")
            return decoded
        } catch {
            print("[CheckIn][QUERY] employeeMirror uid=\(employeeId) error=\(error.localizedDescription)")
            logFirestoreError(prefix: "[CheckIn][QUERY] employeeMirror", error: error)
            throw mapFirestoreError(error)
        }
    }

    func fetchManagerStoreCheckIns(managerId: String, storeId: String, limit: Int = 100) async throws -> [CheckIn] {
        let path = "managerCheckins/\(managerId)/stores/\(storeId)/checkins"
        print("[CheckIn][QUERY] managerMirror managerUid=\(managerId) storeId=\(storeId) path=\(path) orderBy=checkInTime DESC limit=\(limit)")

        do {
            let snapshot = try await db.collection("managerCheckins")
                .document(managerId)
                .collection("stores")
                .document(storeId)
                .collection("checkins")
                .order(by: "checkInTime", descending: true)
                .limit(to: limit)
                .getDocuments()

            let decoded = snapshot.documents.compactMap(decodeCheckIn)
            print("[CheckIn][QUERY] managerMirror managerUid=\(managerId) storeId=\(storeId) count=\(decoded.count)")
            return decoded
        } catch {
            print("[CheckIn][QUERY] managerMirror managerUid=\(managerId) storeId=\(storeId) error=\(error.localizedDescription)")
            logFirestoreError(prefix: "[CheckIn][QUERY] managerMirror", error: error)
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

    private func encode(checkIn: CheckIn, storeData: [String: Any]? = nil) -> [String: Any] {
        let resolvedStoreName = checkIn.storeName.isEmpty
            ? (storeData?["name"] as? String ?? "Store")
            : checkIn.storeName

        [
            "employeeId": checkIn.employeeId,
            "storeId": checkIn.storeId,
            "checkInTime": Timestamp(date: checkIn.checkInTime),
            "createdAt": FieldValue.serverTimestamp(),
            "latitude": checkIn.clientLat,
            "longitude": checkIn.clientLng,
            "clientLat": checkIn.clientLat,
            "clientLng": checkIn.clientLng,
            "distanceMeters": checkIn.distanceMeters,
            "accuracyMeters": checkIn.accuracyMeters,
            "status": checkIn.status.rawValue,
            "rejectReason": checkIn.rejectReason as Any,
            "employeeName": checkIn.employeeName,
            "storeName": resolvedStoreName
        ]
    }

    private func decodeCheckIn(document: QueryDocumentSnapshot) -> CheckIn? {
        let data = document.data()
        guard let employeeId = data["employeeId"] as? String,
              let storeId = data["storeId"] as? String,
              let checkInTime = decodeDate(data["checkInTime"]) else {
            return nil
        }

        return CheckIn(
            id: document.documentID,
            employeeId: employeeId,
            storeId: storeId,
            checkInTime: checkInTime,
            clientLat: (data["latitude"] as? Double) ?? (data["clientLat"] as? Double ?? 0),
            clientLng: (data["longitude"] as? Double) ?? (data["clientLng"] as? Double ?? 0),
            distanceMeters: data["distanceMeters"] as? Double ?? 0,
            accuracyMeters: data["accuracyMeters"] as? Double ?? 0,
            status: CheckInStatus(rawValue: data["status"] as? String ?? "rejected") ?? .rejected,
            rejectReason: data["rejectReason"] as? String,
            employeeName: data["employeeName"] as? String ?? "Employee",
            storeName: data["storeName"] as? String ?? "Store"
        )
    }

    private func decodeDate(_ raw: Any?) -> Date? {
        if let ts = raw as? Timestamp {
            return ts.dateValue()
        }

        if let date = raw as? Date {
            return date
        }

        return nil
    }

    private func mapFirestoreError(_ error: Error) -> Error {
        let nsError = error as NSError

        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code),
           code == .permissionDenied {
            return NSError(
                domain: "StorePass",
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "You don't have permission for this action."]
            )
        }

        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code),
           code == .failedPrecondition {
            return NSError(
                domain: "StorePass",
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "Missing Firestore index for check-ins (employeeId + checkInTime)."]
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
