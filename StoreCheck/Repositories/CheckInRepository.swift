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
    func checkout(checkinId: String, storeId: String, managerId: String?, checkoutLat: Double, checkoutLng: Double, distanceMeters: Double, accuracyMeters: Double) async throws
    func updateCheckIn(_ checkIn: CheckIn) async throws
    func updateCheckInTimes(checkIn: CheckIn, newCheckInTime: Date, newCheckOutTime: Date?) async throws
    func deleteCheckIn(checkinId: String, employeeId: String, storeId: String, managerId: String?) async throws
    func deleteCheckIn(checkinId: String, storeId: String, managerId: String) async throws
    func clearAllCheckIns(isManagerScope: Bool, storeId: String?, managerId: String?) async throws
    func clearAllCheckIns(storeId: String, managerId: String, limit: Int) async throws
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

        let payload = encode(checkIn: checkIn, storeData: storeData, includeCheckoutFields: false)
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

        let preflight = await runRulesPreflight(uid: uid, storeId: checkIn.storeId)

        do {
            print("[CheckIn][WRITE] rootWriteAttempt path=\(rootPath) uid=\(uid) storeId=\(checkIn.storeId)")
            try await db.collection("checkins").document(checkIn.id).setData(payload)
            print("[CheckIn][WRITE] rootWriteSuccess path=\(rootPath)")

            let batch = db.batch()
            batch.setData(payload, forDocument: db.collection("employeeCheckins").document(checkIn.employeeId).collection("checkins").document(checkIn.id))
            batch.setData(payload, forDocument: db.collection("managerCheckins").document(managerId).collection("stores").document(checkIn.storeId).collection("checkins").document(checkIn.id))
            try await batch.commit()
            print("[CheckIn][WRITE] mirrorBatchSuccess employeeMirrorPath=\(employeeMirrorPath) managerMirrorPath=\(managerMirrorPath)")
        } catch {
            logPreflightSummary(preflight: preflight, uid: uid, storeId: checkIn.storeId, prefix: "[RulesPreflight][RootWriteFailure]")
            logFirestoreError(prefix: "[CheckIn] createCheckIn", error: error)
            FirestorePermissionLogger.log(operation: "setData", path: "checkins/\(checkIn.id)", error: error, uid: uid)
            throw mapFirestoreError(error)
        }
    }

    func checkout(
        checkinId: String,
        storeId: String,
        managerId: String?,
        checkoutLat: Double,
        checkoutLng: Double,
        distanceMeters: Double,
        accuracyMeters: Double
    ) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
        }

        let rootRef = db.collection("checkins").document(checkinId)
        let employeeMirrorRef = db.collection("employeeCheckins")
            .document(uid)
            .collection("checkins")
            .document(checkinId)

        let resolvedManagerId = try await resolveManagerId(storeId: storeId, preferredManagerId: managerId)
        let managerMirrorRef = db.collection("managerCheckins")
            .document(resolvedManagerId)
            .collection("stores")
            .document(storeId)
            .collection("checkins")
            .document(checkinId)

        _ = try await db.runTransaction { transaction, errorPointer in
            func fail(_ error: NSError) -> Any? {
                self.logFirestoreError(prefix: "[CheckOut] transaction failed", error: error) // ✅ self.
                errorPointer?.pointee = error
                return nil
            }

            let rootSnap: DocumentSnapshot
            do {
                rootSnap = try transaction.getDocument(rootRef)
            } catch {
                return fail(error as NSError)
            }

            guard let data = rootSnap.data(),
                  let employeeId = data["employeeId"] as? String,
                  employeeId == uid else {
                return fail(NSError(
                    domain: "StorePass",
                    code: 4011,
                    userInfo: [NSLocalizedDescriptionKey: "This check-in cannot be checked out by the current user."]
                ))
            }

            if data["checkOutTime"] != nil {
                return fail(NSError(
                    domain: "StorePass",
                    code: 4012,
                    userInfo: [NSLocalizedDescriptionKey: "Check-out is already completed."]
                ))
            }

            guard let checkInDate = self.decodeDate(data["checkInTime"]) else { // ✅ self.
                return fail(NSError(
                    domain: "StorePass",
                    code: 4013,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid check-in time for checkout."]
                ))
            }

            let checkoutDate = Date()
            let durationSeconds = max(Int(checkoutDate.timeIntervalSince(checkInDate)), 0)

            let payload: [String: Any] = [
                "checkOutTime": Timestamp(date: checkoutDate),
                "checkOutLat": checkoutLat,
                "checkOutLng": checkoutLng,
                "checkOutDistanceMeters": distanceMeters,
                "checkOutAccuracyMeters": accuracyMeters,
                "durationSeconds": durationSeconds
            ]

            print("[CheckOut][WRITE] path=checkins/\(checkinId) keys=\(payload.keys.sorted())")
            print("[CheckOut][WRITE] path=employeeCheckins/\(uid)/checkins/\(checkinId) keys=\(payload.keys.sorted())")
            print("[CheckOut][WRITE] path=managerCheckins/\(resolvedManagerId)/stores/\(storeId)/checkins/\(checkinId) keys=\(payload.keys.sorted())")

            transaction.updateData(payload, forDocument: rootRef)
            transaction.updateData(payload, forDocument: employeeMirrorRef)
            transaction.updateData(payload, forDocument: managerMirrorRef)

            return nil
        }
    }
    

    func updateCheckIn(_ checkIn: CheckIn) async throws {
        let managerId = try await resolveManagerId(storeId: checkIn.storeId, preferredManagerId: nil)
        let payload: [String: Any] = [
            "status": checkIn.status.rawValue,
            "rejectReason": checkIn.rejectReason as Any
        ]
        let batch = db.batch()
        batch.updateData(payload, forDocument: db.collection("checkins").document(checkIn.id))
        batch.updateData(payload, forDocument: db.collection("employeeCheckins").document(checkIn.employeeId).collection("checkins").document(checkIn.id))
        batch.updateData(payload, forDocument: db.collection("managerCheckins").document(managerId).collection("stores").document(checkIn.storeId).collection("checkins").document(checkIn.id))
        try await batch.commit()
    }

    func updateCheckInTimes(checkIn: CheckIn, newCheckInTime: Date, newCheckOutTime: Date?) async throws {
        guard let managerUid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
        }

        let maxAllowed = Date().addingTimeInterval(5 * 60)
        if newCheckInTime > maxAllowed {
            throw NSError(domain: "StorePass", code: 4014, userInfo: [NSLocalizedDescriptionKey: "Check-in time cannot be set in the future."])
        }
        if let newCheckOutTime {
            if newCheckOutTime > maxAllowed {
                throw NSError(domain: "StorePass", code: 4015, userInfo: [NSLocalizedDescriptionKey: "Check-out time cannot be set in the future."])
            }
            if newCheckInTime > newCheckOutTime {
                throw NSError(domain: "StorePass", code: 4016, userInfo: [NSLocalizedDescriptionKey: "Check-in time must be before check-out time."])
            }
        }

        let managerId = try await resolveManagerId(storeId: checkIn.storeId, preferredManagerId: managerUid)
        let payload: [String: Any] = [
            "checkInTime": Timestamp(date: newCheckInTime),
            "checkOutTime": newCheckOutTime.map { Timestamp(date: $0) } ?? NSNull(),
            "updatedAt": FieldValue.serverTimestamp()
        ]

        let batch = db.batch()
        batch.updateData(payload, forDocument: db.collection("checkins").document(checkIn.id))
        batch.updateData(payload, forDocument: db.collection("employeeCheckins").document(checkIn.employeeId).collection("checkins").document(checkIn.id))
        batch.updateData(payload, forDocument: db.collection("managerCheckins").document(managerId).collection("stores").document(checkIn.storeId).collection("checkins").document(checkIn.id))

        do {
            try await batch.commit()
        } catch {
            print("[ManagerEditTimes] error=\(error.localizedDescription)")
            throw mapFirestoreError(error)
        }
    }

    func deleteCheckIn(checkinId: String, employeeId: String, storeId: String, managerId: String?) async throws {
        await logOperationContext(
            operation: "employee_delete_checkin",
            paths: [
                "checkins/\(checkinId)",
                "employeeCheckins/\(employeeId)/checkins/\(checkinId)",
                "managerCheckins/<resolved>/stores/\(storeId)/checkins/\(checkinId)"
            ]
        )
        let managerId = try await resolveManagerId(storeId: storeId, preferredManagerId: managerId)
        let batch = db.batch()
        batch.deleteDocument(db.collection("checkins").document(checkinId))
        batch.deleteDocument(db.collection("employeeCheckins").document(employeeId).collection("checkins").document(checkinId))
        batch.deleteDocument(db.collection("managerCheckins").document(managerId).collection("stores").document(storeId).collection("checkins").document(checkinId))
        try await batch.commit()
    }

    func deleteCheckIn(checkinId: String, storeId: String, managerId: String) async throws {
        await logOperationContext(
            operation: "manager_delete_checkin",
            paths: [
                "checkins/\(checkinId)",
                "managerCheckins/\(managerId)/stores/\(storeId)/checkins/\(checkinId)",
                "employeeCheckins/<resolvedEmployee>/checkins/\(checkinId)"
            ]
        )
        let managerMirrorRef = db.collection("managerCheckins")
            .document(managerId)
            .collection("stores")
            .document(storeId)
            .collection("checkins")
            .document(checkinId)

        let managerMirror = try await managerMirrorRef.getDocument()
        let employeeId = managerMirror.data()?["employeeId"] as? String

        let batch = db.batch()
        batch.deleteDocument(db.collection("checkins").document(checkinId))
        if let employeeId, !employeeId.isEmpty {
            batch.deleteDocument(db.collection("employeeCheckins").document(employeeId).collection("checkins").document(checkinId))
        }
        batch.deleteDocument(managerMirrorRef)
        try await batch.commit()
    }

    func clearAllCheckIns(isManagerScope: Bool, storeId: String?, managerId: String?) async throws {
        await logOperationContext(
            operation: isManagerScope ? "manager_clear_all_checkins" : "employee_clear_all_checkins",
            paths: [
                isManagerScope
                    ? "managerCheckins/\(managerId ?? "<resolved>")/stores/\(storeId ?? "<missing>")/checkins/*"
                    : "employeeCheckins/\(Auth.auth().currentUser?.uid ?? "<nil>")/checkins/*"
            ]
        )
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
        }

        if isManagerScope {
            guard let storeId else { return }
            let manager = try await resolveManagerId(storeId: storeId, preferredManagerId: managerId)
            try await clearAllCheckIns(storeId: storeId, managerId: manager, limit: 500)
        } else {
            let snap = try await db.collection("employeeCheckins").document(uid).collection("checkins").getDocuments()
            for document in snap.documents {
                let data = document.data()
                let storeId = data["storeId"] as? String ?? ""
                let manager = data["managerId"] as? String
                try await deleteCheckIn(checkinId: document.documentID, employeeId: uid, storeId: storeId, managerId: manager)
            }
        }
    }

    func clearAllCheckIns(storeId: String, managerId: String, limit: Int = 500) async throws {
        let queryLimit = max(1, min(limit, 500))

        let managerSnapshot = try await db.collection("managerCheckins")
            .document(managerId)
            .collection("stores")
            .document(storeId)
            .collection("checkins")
            .limit(to: queryLimit)
            .getDocuments()

        if managerSnapshot.documents.isEmpty { return }

        // Local chunk helper (avoids fileprivate extension visibility issues)
        func chunkDocuments<T>(_ items: [T], size: Int) -> [[T]] {
            guard size > 0 else { return [items] }
            var result: [[T]] = []
            result.reserveCapacity((items.count + size - 1) / size)
            var index = 0
            while index < items.count {
                let end = min(index + size, items.count)
                result.append(Array(items[index..<end]))
                index = end
            }
            return result
        }

        // 150 deletes per batch is safe (Firestore limit is 500 ops per batch)
        let chunks = chunkDocuments(managerSnapshot.documents, size: 150)

        for chunk in chunks {
            let batch = db.batch()

            for document in chunk {
                let checkinId = document.documentID
                let employeeId = document.data()["employeeId"] as? String

                batch.deleteDocument(db.collection("checkins").document(checkinId))

                if let employeeId, !employeeId.isEmpty {
                    batch.deleteDocument(
                        db.collection("employeeCheckins")
                            .document(employeeId)
                            .collection("checkins")
                            .document(checkinId)
                    )
                }

                batch.deleteDocument(
                    db.collection("managerCheckins")
                        .document(managerId)
                        .collection("stores")
                        .document(storeId)
                        .collection("checkins")
                        .document(checkinId)
                )
            }

            try await batch.commit()
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
        print("[CheckIn][QUERY] path=\(path) uid=\(employeeId) storeId=nil orderBy=checkInTime DESC limit=\(limit)")
        print("[CheckIn][QUERY] indexHint=none")

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
            logFirestoreError(prefix: "[CheckIn][QUERY] employeeMirror", error: error)
            throw mapFirestoreError(error)
        }
    }

    func fetchManagerStoreCheckIns(managerId: String, storeId: String, limit: Int = 100) async throws -> [CheckIn] {
        let path = "managerCheckins/\(managerId)/stores/\(storeId)/checkins"
        print("[CheckIn][QUERY] path=\(path) uid=\(managerId) storeId=\(storeId) orderBy=checkInTime DESC limit=\(limit)")
        print("[CheckIn][QUERY] indexHint=none")

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

    private func encode(checkIn: CheckIn, storeData: [String: Any]? = nil, includeCheckoutFields: Bool) -> [String: Any] {
        let resolvedStoreName = checkIn.storeName.isEmpty
            ? (storeData?["name"] as? String ?? "Store")
            : checkIn.storeName

        var payload: [String: Any] = [
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
            "employeeEmail": checkIn.employeeEmail as Any,
            "storeName": resolvedStoreName,
            "managerId": storeData?["managerId"] as Any
        ]

        if includeCheckoutFields {
            if let checkOutTime = checkIn.checkOutTime {
                payload["checkOutTime"] = Timestamp(date: checkOutTime)
            }
            if let checkOutLat = checkIn.checkOutLat {
                payload["checkOutLat"] = checkOutLat
            }
            if let checkOutLng = checkIn.checkOutLng {
                payload["checkOutLng"] = checkOutLng
            }
            if let checkOutDistanceMeters = checkIn.checkOutDistanceMeters {
                payload["checkOutDistanceMeters"] = checkOutDistanceMeters
            }
            if let checkOutAccuracyMeters = checkIn.checkOutAccuracyMeters {
                payload["checkOutAccuracyMeters"] = checkOutAccuracyMeters
            }
            if let durationSeconds = checkIn.durationSeconds {
                payload["durationSeconds"] = durationSeconds
            }
        }

        return payload
    }

    private struct RulesPreflightSnapshot {
        var userDocExists = false
        var role: String?
        var isActive: Bool?
        var assignedStoreIdsCount = 0
        var assignedStoreIdsContains = false
        var membershipExists = false
        var employeeStoreMirrorExists = false
        var storeExists = false
        var storeManagerId: String?
        var storeIsActive: Bool?
    }

    private func runRulesPreflight(uid: String, storeId: String) async -> RulesPreflightSnapshot {
        var preflight = RulesPreflightSnapshot()

        do {
            let userDoc = try await db.collection("users").document(uid).getDocument(source: .server)
            preflight.userDocExists = userDoc.exists

            let userData = userDoc.data() ?? [:]
            preflight.role = userData["role"] as? String
            preflight.isActive = userData["isActive"] as? Bool

            let assignedStoreIds = userData["assignedStoreIds"] as? [String] ?? []
            preflight.assignedStoreIdsCount = assignedStoreIds.count
            preflight.assignedStoreIdsContains = assignedStoreIds.contains(storeId)

            let roleStr = preflight.role ?? "nil"
            let activeStr = String(describing: preflight.isActive)

            print("[RulesPreflight][users] uid=\(uid) storeId=\(storeId) userDocExists=\(preflight.userDocExists) role=\(roleStr) isActive=\(activeStr) assignedStoreIdsCount=\(preflight.assignedStoreIdsCount) assignedStoreIdsContains=\(preflight.assignedStoreIdsContains)")
        } catch {
            logFirestoreError(prefix: "[RulesPreflight][users] uid=\(uid) storeId=\(storeId)", error: error)
        }

        do {
            let memberDoc = try await db.collection("stores").document(storeId)
                .collection("members").document(uid)
                .getDocument(source: .server)

            preflight.membershipExists = memberDoc.exists
            print("[RulesPreflight][members] uid=\(uid) storeId=\(storeId) membershipExists=\(preflight.membershipExists)")
        } catch {
            logFirestoreError(prefix: "[RulesPreflight][members] uid=\(uid) storeId=\(storeId)", error: error)
        }

        do {
            let employeeStoreDoc = try await db.collection("employeeStores").document(uid)
                .collection("stores").document(storeId)
                .getDocument(source: .server)

            preflight.employeeStoreMirrorExists = employeeStoreDoc.exists
            print("[RulesPreflight][employeeStores] uid=\(uid) storeId=\(storeId) employeeStoreMirrorExists=\(preflight.employeeStoreMirrorExists)")
        } catch {
            logFirestoreError(prefix: "[RulesPreflight][employeeStores] uid=\(uid) storeId=\(storeId)", error: error)
        }

        do {
            let storeDoc = try await db.collection("stores").document(storeId).getDocument(source: .server)
            preflight.storeExists = storeDoc.exists

            let storeData = storeDoc.data() ?? [:]
            preflight.storeManagerId = storeData["managerId"] as? String
            preflight.storeIsActive = storeData["isActive"] as? Bool

            let managerIdStr = preflight.storeManagerId ?? "nil"
            let storeActiveStr = String(describing: preflight.storeIsActive)

            print("[RulesPreflight][store] uid=\(uid) storeId=\(storeId) storeExists=\(preflight.storeExists) managerId=\(managerIdStr) isActive=\(storeActiveStr)")
        } catch {
            logFirestoreError(prefix: "[RulesPreflight][store] uid=\(uid) storeId=\(storeId)", error: error)
        }

        logPreflightSummary(preflight: preflight, uid: uid, storeId: storeId, prefix: "[RulesPreflight]")
        return preflight
    }

    private func logPreflightSummary(preflight: RulesPreflightSnapshot, uid: String, storeId: String, prefix: String) {
        print("\(prefix) uid=\(uid) storeId=\(storeId) assignedStoreIdsContains=\(preflight.assignedStoreIdsContains) membershipExists=\(preflight.membershipExists) employeeStoreMirrorExists=\(preflight.employeeStoreMirrorExists) storeExists=\(preflight.storeExists)")
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
            checkOutTime: decodeDate(data["checkOutTime"]),
            clientLat: (data["latitude"] as? Double) ?? (data["clientLat"] as? Double ?? 0),
            clientLng: (data["longitude"] as? Double) ?? (data["clientLng"] as? Double ?? 0),
            distanceMeters: data["distanceMeters"] as? Double ?? 0,
            accuracyMeters: data["accuracyMeters"] as? Double ?? 0,
            checkOutLat: data["checkOutLat"] as? Double,
            checkOutLng: data["checkOutLng"] as? Double,
            checkOutDistanceMeters: data["checkOutDistanceMeters"] as? Double,
            checkOutAccuracyMeters: data["checkOutAccuracyMeters"] as? Double,
            durationSeconds: data["durationSeconds"] as? Int,
            status: CheckInStatus(rawValue: data["status"] as? String ?? "rejected") ?? .rejected,
            rejectReason: data["rejectReason"] as? String,
            employeeName: data["employeeName"] as? String ?? "Employee",
            employeeEmail: data["employeeEmail"] as? String,
            storeName: data["storeName"] as? String ?? "Store"
        )
    }

    private func resolveManagerId(storeId: String, preferredManagerId: String?) async throws -> String {
        if let preferredManagerId, !preferredManagerId.isEmpty {
            return preferredManagerId
        }
        let storeSnapshot = try await db.collection("stores").document(storeId).getDocument()
        guard let managerId = storeSnapshot.data()?["managerId"] as? String, !managerId.isEmpty else {
            throw NSError(domain: "StorePass", code: 4010, userInfo: [NSLocalizedDescriptionKey: "Store manager could not be resolved."])
        }
        return managerId
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


    private func logOperationContext(operation: String, paths: [String]) async {
        let uid = Auth.auth().currentUser?.uid ?? "nil"
        let providerIDs = Auth.auth().currentUser?.providerData.map(\.providerID) ?? []
        var role = "nil"
        var isActive = "nil"

        if uid != "nil" {
            do {
                let doc = try await db.collection("users").document(uid).getDocument()
                role = (doc.data()?["role"] as? String) ?? "nil"
                if let active = doc.data()?["isActive"] as? Bool {
                    isActive = String(active)
                }
            } catch {
                print("[CheckInOp] operation=\(operation) uid=\(uid) profileLookupError=\(error.localizedDescription)")
            }
        }

        print("[CheckInOp] operation=\(operation) uid=\(uid) providerIDs=\(providerIDs) role=\(role) isActive=\(isActive) paths=\(paths)")
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
