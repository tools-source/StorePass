import CloudKit
import Foundation

struct CheckInFilter {
    var storeId: String?
    var status: CheckInStatus?
    var date: Date = Date()
}

@MainActor
protocol CheckInRepositoryProtocol {
    @discardableResult
    func listenToTodaysCheckIns(
        filter: CheckInFilter,
        onUpdate: @escaping ([CheckIn]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> CheckInListenerToken

    func createCheckIn(_ checkIn: CheckIn, checkInPhotoData: Data) async throws

    func checkout(
        checkinId: String,
        storeId: String,
        managerId: String?,
        checkoutLat: Double,
        checkoutLng: Double,
        distanceMeters: Double,
        accuracyMeters: Double,
        verification: Verify2ReadEvidence,
        checkOutPhotoData: Data
    ) async throws

    func updateCheckIn(_ checkIn: CheckIn) async throws
    func updateCheckInTimes(checkIn: CheckIn, newCheckInTime: Date, newCheckOutTime: Date?) async throws
    func deleteCheckIn(checkinId: String, employeeId: String, storeId: String, managerId: String?) async throws
    func deleteCheckIn(checkinId: String, storeId: String, managerId: String) async throws
    func clearAllCheckIns(isManagerScope: Bool, storeId: String?, managerId: String?) async throws
    func clearAllCheckIns(storeId: String, managerId: String, limit: Int) async throws
    func fetchCheckIns(employeeId: String?, limit: Int) async throws -> [CheckIn]
    func fetchEmployeeCheckIns(employeeId: String, limit: Int) async throws -> [CheckIn]
    func fetchManagerStoreCheckIns(managerId: String, storeId: String, fromDate: Date, toDate: Date, employeeId: String?, limit: Int) async throws -> [CheckIn]
    func fetchTodaysCheckIns(filter: CheckInFilter) async throws -> [CheckIn]
    func fetchVerificationPhotoData(checkInId: String, storeId: String) async throws -> Data?
    func fetchVerificationPhotoURL(photoPath: String) async throws -> URL
}

protocol CheckInListenerToken {
    func cancel()
}

extension CKSchema {
    enum CheckInField {
        static let sessionId = "sessionId"
        static let storeRef = "storeRef"
        static let storeId = "storeId"
        static let employeeUserRef = "employeeUserRef"
        static let employeeUserId = "employeeUserId"
        static let managerUserId = "managerUserId"
        static let checkInAt = "checkInAt"
        static let checkOutAt = "checkOutAt"
        static let durationSeconds = "durationSeconds"
        static let checkInPhotoAsset = "checkInPhotoAsset"
        static let checkOutPhotoAsset = "checkOutPhotoAsset"
        static let checkInLocationLat = "checkInLocationLat"
        static let checkInLocationLng = "checkInLocationLng"
        static let checkInDistanceMeters = "checkInDistanceMeters"
        static let checkInAccuracyMeters = "checkInAccuracyMeters"
        static let checkOutLocationLat = "checkOutLocationLat"
        static let checkOutLocationLng = "checkOutLocationLng"
        static let checkOutDistanceMeters = "checkOutDistanceMeters"
        static let checkOutAccuracyMeters = "checkOutAccuracyMeters"
        static let status = "status"
        static let rejectReason = "rejectReason"
        static let employeeName = "employeeName"
        static let employeeEmail = "employeeEmail"
        static let storeName = "storeName"
        static let verifyVersion = "verifyVersion"
        static let verifyMethod = "verifyMethod"
        static let verifyInInside = "verifyInInside"
        static let verifyInDistance1Meters = "verifyInDistance1Meters"
        static let verifyInDistance2Meters = "verifyInDistance2Meters"
        static let verifyInDriftMeters = "verifyInDriftMeters"
        static let verifyInRead1At = "verifyInRead1At"
        static let verifyInRead2At = "verifyInRead2At"
        static let verifyInAccuracy1Meters = "verifyInAccuracy1Meters"
        static let verifyInAccuracy2Meters = "verifyInAccuracy2Meters"
        static let verifyOutInside = "verifyOutInside"
        static let verifyOutDistance1Meters = "verifyOutDistance1Meters"
        static let verifyOutDistance2Meters = "verifyOutDistance2Meters"
        static let verifyOutDriftMeters = "verifyOutDriftMeters"
        static let verifyOutRead1At = "verifyOutRead1At"
        static let verifyOutRead2At = "verifyOutRead2At"
        static let verifyOutAccuracy1Meters = "verifyOutAccuracy1Meters"
        static let verifyOutAccuracy2Meters = "verifyOutAccuracy2Meters"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
    }
}

private final class PollingCheckInListenerToken: CheckInListenerToken {
    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class CloudKitCheckInRepository: CheckInRepositoryProtocol {
    private let service: CloudKitService
    private let userProfileStore: UserProfileStoreProtocol
    private static let localCheckInsKey = "storecheck.local_checkins.v1"
    private static let localManagerStoresKey = "storecheck.local_manager_stores.v1"
    private static let localPhotoDirectoryName = "storecheck_local_photos"
    private var isCloudKitIdentityMismatchDetected = false

    init(service: CloudKitService, userProfileStore: UserProfileStoreProtocol) {
        self.service = service
        self.userProfileStore = userProfileStore
    }

    private var isLocalOnlyModeEnabled: Bool {
        isCloudKitIdentityMismatchDetected || service.isCloudKitIdentityMismatchDetected
    }

    @discardableResult
    func listenToTodaysCheckIns(
        filter: CheckInFilter,
        onUpdate: @escaping ([CheckIn]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> CheckInListenerToken {
        let pollingTask = Task {
            var previousSignature: String?

            while !Task.isCancelled {
                do {
                    let sessions = try await fetchTodaysCheckIns(filter: filter)
                    let signature = Self.signature(for: sessions)
                    if signature != previousSignature {
                        previousSignature = signature
                        onUpdate(sessions)
                    }
                } catch {
                    onError(error)
                }

                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }

        return PollingCheckInListenerToken(task: pollingTask)
    }

    func createCheckIn(_ checkIn: CheckIn, checkInPhotoData: Data) async throws {
        let currentUserId = try service.requireCurrentUserId()
        guard checkIn.employeeId == currentUserId else {
            throw CloudKitClientError.unauthorized
        }

        guard !checkIn.storeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudKitClientError.invalidData("Store information is missing.")
        }

        guard !checkInPhotoData.isEmpty else {
            throw CloudKitClientError.invalidData("A photo is required to check in.")
        }

        if isLocalOnlyModeEnabled {
            try persistLocalCheckIn(checkIn, employeeId: currentUserId, checkInPhotoData: checkInPhotoData)
            return
        }

        try await service.ensureCloudKitAvailable()

        do {
            try await ensureActiveMembership(employeeId: currentUserId, storeId: checkIn.storeId)

            let activeSessions = try await fetchActiveSessions(employeeId: currentUserId, storeId: checkIn.storeId)
            guard activeSessions.isEmpty else {
                throw CloudKitClientError.invalidData("You already have an active check-in for this store.")
            }

            let storeRecordID = CloudKitService.storeRecordID(storeId: checkIn.storeId)
            guard let storeRecord = try await service.fetchRecord(with: storeRecordID),
                  let managerUserId = storeRecord.string(CKSchema.StoreField.managerUserId),
                  storeRecord.bool(CKSchema.StoreField.isActive, default: true) else {
                throw CloudKitClientError.missingRecord("Store is unavailable.")
            }

            let checkInRecordID = CloudKitService.checkInRecordID(checkInId: checkIn.id)
            let record = CKRecord(recordType: CKSchema.RecordType.checkInSession, recordID: checkInRecordID)

            record[CKSchema.CheckInField.sessionId] = checkIn.id as CKRecordValue
            record[CKSchema.CheckInField.storeId] = checkIn.storeId as CKRecordValue
            record[CKSchema.CheckInField.storeRef] = CKRecord.Reference(recordID: storeRecordID, action: .none)
            record[CKSchema.CheckInField.employeeUserId] = checkIn.employeeId as CKRecordValue
            if let publicUserRecordID = await userProfileStore.resolvePublicUserRecordID(userId: checkIn.employeeId) {
                record[CKSchema.CheckInField.employeeUserRef] = CKRecord.Reference(recordID: publicUserRecordID, action: .none)
            } else {
                record[CKSchema.CheckInField.employeeUserRef] = nil
            }
            record[CKSchema.CheckInField.managerUserId] = managerUserId as CKRecordValue

            record[CKSchema.CheckInField.checkInAt] = checkIn.checkInTime as CKRecordValue
            record[CKSchema.CheckInField.checkInLocationLat] = NSNumber(value: checkIn.clientLat)
            record[CKSchema.CheckInField.checkInLocationLng] = NSNumber(value: checkIn.clientLng)
            record[CKSchema.CheckInField.checkInDistanceMeters] = NSNumber(value: checkIn.distanceMeters)
            record[CKSchema.CheckInField.checkInAccuracyMeters] = NSNumber(value: checkIn.accuracyMeters)

            record[CKSchema.CheckInField.status] = checkIn.status.rawValue as CKRecordValue
            if let rejectReason = checkIn.rejectReason, !rejectReason.isEmpty {
                record[CKSchema.CheckInField.rejectReason] = rejectReason as CKRecordValue
            }

            record[CKSchema.CheckInField.employeeName] = checkIn.employeeName as CKRecordValue
            if let employeeEmail = checkIn.employeeEmail, !employeeEmail.isEmpty {
                record[CKSchema.CheckInField.employeeEmail] = employeeEmail as CKRecordValue
            }
            record[CKSchema.CheckInField.storeName] = checkIn.storeName as CKRecordValue

            encodeVerificationIn(record: record, from: checkIn)

            let now = Date()
            record[CKSchema.CheckInField.createdAt] = now as CKRecordValue
            record[CKSchema.CheckInField.updatedAt] = now as CKRecordValue

            let assetURL = try makeTemporaryAssetFile(data: checkInPhotoData, prefix: "checkin_\(checkIn.id)")
            defer { try? FileManager.default.removeItem(at: assetURL) }
            record[CKSchema.CheckInField.checkInPhotoAsset] = CKAsset(fileURL: assetURL)

            _ = try await service.save(record: record)
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "createCheckIn")
            guard shouldUseLocalReadFallback(for: error) else {
                throw error
            }
            AppLog.warning(
                "Check-in create fell back to local persistence session=\(checkIn.id): \(AppLog.sanitize(error.localizedDescription))"
            )
            try persistLocalCheckIn(checkIn, employeeId: currentUserId, checkInPhotoData: checkInPhotoData)
        }
    }

    func checkout(
        checkinId: String,
        storeId: String,
        managerId: String?,
        checkoutLat: Double,
        checkoutLng: Double,
        distanceMeters: Double,
        accuracyMeters: Double,
        verification: Verify2ReadEvidence,
        checkOutPhotoData: Data
    ) async throws {
        let currentUserId = try service.requireCurrentUserId()
        guard !checkOutPhotoData.isEmpty else {
            throw CloudKitClientError.invalidData("A photo is required to check out.")
        }

        if isLocalOnlyModeEnabled {
            try checkoutLocalCheckIn(
                checkinId: checkinId,
                storeId: storeId,
                employeeId: currentUserId,
                checkoutLat: checkoutLat,
                checkoutLng: checkoutLng,
                distanceMeters: distanceMeters,
                accuracyMeters: accuracyMeters,
                verification: verification,
                checkOutPhotoData: checkOutPhotoData
            )
            return
        }

        try await service.ensureCloudKitAvailable()

        do {
            try await ensureActiveMembership(employeeId: currentUserId, storeId: storeId)

            let checkInRecordID = CloudKitService.checkInRecordID(checkInId: checkinId)
            guard let record = try await service.fetchRecord(with: checkInRecordID) else {
                throw CloudKitClientError.missingRecord("Check-in session not found.")
            }

            guard record.string(CKSchema.CheckInField.employeeUserId) == currentUserId else {
                throw CloudKitClientError.unauthorized
            }

            guard record.date(CKSchema.CheckInField.checkOutAt) == nil else {
                throw CloudKitClientError.invalidData("This session is already checked out.")
            }

            if let managerId, let recordManagerId = record.string(CKSchema.CheckInField.managerUserId), !recordManagerId.isEmpty, managerId != recordManagerId {
                throw CloudKitClientError.invalidData("Session manager mismatch.")
            }

            let checkInAt = record.date(CKSchema.CheckInField.checkInAt) ?? Date()
            let checkoutTime = Date()
            let durationSeconds = max(Int(checkoutTime.timeIntervalSince(checkInAt)), 0)

            record[CKSchema.CheckInField.checkOutAt] = checkoutTime as CKRecordValue
            record[CKSchema.CheckInField.checkOutLocationLat] = NSNumber(value: checkoutLat)
            record[CKSchema.CheckInField.checkOutLocationLng] = NSNumber(value: checkoutLng)
            record[CKSchema.CheckInField.checkOutDistanceMeters] = NSNumber(value: distanceMeters)
            record[CKSchema.CheckInField.checkOutAccuracyMeters] = NSNumber(value: accuracyMeters)
            record[CKSchema.CheckInField.durationSeconds] = NSNumber(value: durationSeconds)

            record[CKSchema.CheckInField.verifyMethod] = verification.method as CKRecordValue
            record[CKSchema.CheckInField.verifyVersion] = NSNumber(value: verification.version)
            record[CKSchema.CheckInField.verifyOutInside] = NSNumber(value: verification.inside)
            record[CKSchema.CheckInField.verifyOutDistance1Meters] = NSNumber(value: verification.distance1Meters)
            record[CKSchema.CheckInField.verifyOutDistance2Meters] = NSNumber(value: verification.distance2Meters)
            record[CKSchema.CheckInField.verifyOutDriftMeters] = NSNumber(value: verification.driftMeters)
            record[CKSchema.CheckInField.verifyOutRead1At] = verification.read1At as CKRecordValue
            record[CKSchema.CheckInField.verifyOutRead2At] = verification.read2At as CKRecordValue
            record[CKSchema.CheckInField.verifyOutAccuracy1Meters] = NSNumber(value: verification.read1Accuracy)
            record[CKSchema.CheckInField.verifyOutAccuracy2Meters] = NSNumber(value: verification.read2Accuracy)
            record[CKSchema.CheckInField.updatedAt] = Date() as CKRecordValue

            let assetURL = try makeTemporaryAssetFile(data: checkOutPhotoData, prefix: "checkout_\(checkinId)")
            defer { try? FileManager.default.removeItem(at: assetURL) }
            record[CKSchema.CheckInField.checkOutPhotoAsset] = CKAsset(fileURL: assetURL)

            _ = try await service.save(record: record)
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "checkout")
            guard shouldUseLocalReadFallback(for: error) else {
                throw error
            }
            AppLog.warning(
                "Check-out fell back to local persistence session=\(checkinId): \(AppLog.sanitize(error.localizedDescription))"
            )
            try checkoutLocalCheckIn(
                checkinId: checkinId,
                storeId: storeId,
                employeeId: currentUserId,
                checkoutLat: checkoutLat,
                checkoutLng: checkoutLng,
                distanceMeters: distanceMeters,
                accuracyMeters: accuracyMeters,
                verification: verification,
                checkOutPhotoData: checkOutPhotoData
            )
        }
    }

    func updateCheckIn(_ checkIn: CheckIn) async throws {
        let currentUserId = try service.requireCurrentUserId()
        guard service.currentRole == .manager else {
            throw CloudKitClientError.unauthorized
        }
        if isLocalOnlyModeEnabled {
            try updateLocalCheckIn(checkInId: checkIn.id, managerId: currentUserId) { session in
                session.status = checkIn.status
                session.rejectReason = checkIn.rejectReason
            }
            return
        }

        do {
            try await service.ensureCloudKitAvailable()

            let recordID = CloudKitService.checkInRecordID(checkInId: checkIn.id)
            guard let record = try await service.fetchRecord(with: recordID) else {
                throw CloudKitClientError.missingRecord("Check-in session not found.")
            }

            let managerId = record.string(CKSchema.CheckInField.managerUserId)
            guard managerId == currentUserId else {
                throw CloudKitClientError.unauthorized
            }

            record[CKSchema.CheckInField.status] = checkIn.status.rawValue as CKRecordValue
            if let rejectReason = checkIn.rejectReason, !rejectReason.isEmpty {
                record[CKSchema.CheckInField.rejectReason] = rejectReason as CKRecordValue
            } else {
                record[CKSchema.CheckInField.rejectReason] = nil
            }
            record[CKSchema.CheckInField.updatedAt] = Date() as CKRecordValue

            _ = try await service.save(record: record)
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "updateCheckIn")
            guard shouldUseLocalReadFallback(for: error) else {
                throw error
            }
            AppLog.warning("Check-in status update recovered in local-only mode id=\(checkIn.id)")
            try updateLocalCheckIn(checkInId: checkIn.id, managerId: currentUserId) { session in
                session.status = checkIn.status
                session.rejectReason = checkIn.rejectReason
            }
        }
    }

    func updateCheckInTimes(checkIn: CheckIn, newCheckInTime: Date, newCheckOutTime: Date?) async throws {
        let currentUserId = try service.requireCurrentUserId()
        guard service.currentRole == .manager else {
            throw CloudKitClientError.unauthorized
        }
        if isLocalOnlyModeEnabled {
            try updateLocalCheckIn(checkInId: checkIn.id, managerId: currentUserId) { session in
                session.checkInTime = newCheckInTime
                session.checkOutTime = newCheckOutTime
                if let newCheckOutTime {
                    session.durationSeconds = max(Int(newCheckOutTime.timeIntervalSince(newCheckInTime)), 0)
                } else {
                    session.durationSeconds = nil
                }
            }
            return
        }

        do {
            try await service.ensureCloudKitAvailable()

            let recordID = CloudKitService.checkInRecordID(checkInId: checkIn.id)
            guard let record = try await service.fetchRecord(with: recordID) else {
                throw CloudKitClientError.missingRecord("Check-in session not found.")
            }

            let managerId = record.string(CKSchema.CheckInField.managerUserId)
            guard managerId == currentUserId else {
                throw CloudKitClientError.unauthorized
            }

            record[CKSchema.CheckInField.checkInAt] = newCheckInTime as CKRecordValue
            if let newCheckOutTime {
                record[CKSchema.CheckInField.checkOutAt] = newCheckOutTime as CKRecordValue
                let duration = max(Int(newCheckOutTime.timeIntervalSince(newCheckInTime)), 0)
                record[CKSchema.CheckInField.durationSeconds] = NSNumber(value: duration)
            } else {
                record[CKSchema.CheckInField.checkOutAt] = nil
                record[CKSchema.CheckInField.durationSeconds] = nil
            }
            record[CKSchema.CheckInField.updatedAt] = Date() as CKRecordValue

            _ = try await service.save(record: record)
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "updateCheckInTimes")
            guard shouldUseLocalReadFallback(for: error) else {
                throw error
            }
            AppLog.warning("Check-in time edit recovered in local-only mode id=\(checkIn.id)")
            try updateLocalCheckIn(checkInId: checkIn.id, managerId: currentUserId) { session in
                session.checkInTime = newCheckInTime
                session.checkOutTime = newCheckOutTime
                if let newCheckOutTime {
                    session.durationSeconds = max(Int(newCheckOutTime.timeIntervalSince(newCheckInTime)), 0)
                } else {
                    session.durationSeconds = nil
                }
            }
        }
    }

    func deleteCheckIn(checkinId: String, employeeId: String, storeId: String, managerId: String?) async throws {
        _ = employeeId
        _ = storeId

        try await service.ensureCloudKitAvailable()
        let currentUserId = try service.requireCurrentUserId()

        let recordID = CloudKitService.checkInRecordID(checkInId: checkinId)
        guard let record = try await service.fetchRecord(with: recordID) else {
            return
        }

        let isOwner = record.string(CKSchema.CheckInField.employeeUserId) == currentUserId
        let isManager = record.string(CKSchema.CheckInField.managerUserId) == currentUserId
        let allowedByManagerParam = managerId == nil || managerId == currentUserId

        guard (isOwner || isManager), allowedByManagerParam else {
            throw CloudKitClientError.unauthorized
        }

        try await service.deleteRecord(with: recordID)
    }

    func deleteCheckIn(checkinId: String, storeId: String, managerId: String) async throws {
        _ = storeId

        try await service.ensureCloudKitAvailable()
        let currentUserId = try service.requireCurrentUserId()
        guard currentUserId == managerId else {
            throw CloudKitClientError.unauthorized
        }

        let recordID = CloudKitService.checkInRecordID(checkInId: checkinId)
        guard let record = try await service.fetchRecord(with: recordID) else {
            return
        }

        guard record.string(CKSchema.CheckInField.managerUserId) == managerId else {
            throw CloudKitClientError.unauthorized
        }

        try await service.deleteRecord(with: recordID)
    }

    func clearAllCheckIns(isManagerScope: Bool, storeId: String?, managerId: String?) async throws {
        if isManagerScope {
            guard let storeId, let managerId else { return }
            try await clearAllCheckIns(storeId: storeId, managerId: managerId, limit: 500)
            return
        }

        let currentUserId = try service.requireCurrentUserId()
        if isLocalOnlyModeEnabled {
            clearLocalCheckInsForEmployee(employeeId: currentUserId)
            return
        }

        let predicate = NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, currentUserId)
        do {
            let records = try await service.queryRecords(recordType: CKSchema.RecordType.checkInSession, predicate: predicate)
            let recordIds = records.map(\.recordID)
            if !recordIds.isEmpty {
                _ = try await service.modify(recordsToSave: [], recordIDsToDelete: recordIds, atomic: false)
            }
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "clearAllCheckIns.employee")
            guard isRecoverableReadError(error) else {
                throw error
            }
        }

        clearLocalCheckInsForEmployee(employeeId: currentUserId)
    }

    func clearAllCheckIns(storeId: String, managerId: String, limit: Int) async throws {
        _ = limit

        let currentUserId = try service.requireCurrentUserId()
        guard currentUserId == managerId else {
            throw CloudKitClientError.unauthorized
        }

        if isLocalOnlyModeEnabled {
            clearLocalCheckInsForStore(managerId: managerId, storeId: storeId)
            return
        }

        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K == %@", CKSchema.CheckInField.managerUserId, managerId),
            NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, storeId)
        ])

        do {
            let records = try await service.queryRecords(recordType: CKSchema.RecordType.checkInSession, predicate: predicate)
            let recordIds = records.map(\.recordID)
            if !recordIds.isEmpty {
                _ = try await service.modify(recordsToSave: [], recordIDsToDelete: recordIds, atomic: false)
            }
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "clearAllCheckIns.manager")
            guard isRecoverableReadError(error) else {
                throw error
            }
        }

        clearLocalCheckInsForStore(managerId: managerId, storeId: storeId)
    }

    func fetchCheckIns(employeeId: String?, limit: Int) async throws -> [CheckIn] {
        if let employeeId {
            return try await fetchEmployeeCheckIns(employeeId: employeeId, limit: limit)
        }

        let currentUserId = try service.requireCurrentUserId()
        let role = service.currentRole

        let predicate: NSPredicate
        if role == .manager {
            predicate = NSPredicate(format: "%K == %@", CKSchema.CheckInField.managerUserId, currentUserId)
        } else {
            predicate = NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, currentUserId)
        }

        let managerLocalFallback: [CheckIn]
        if role == .manager {
            managerLocalFallback = localManagerCheckIns(managerId: currentUserId)
        } else {
            managerLocalFallback = []
        }

        if isLocalOnlyModeEnabled {
            guard role != .manager else { return Array(managerLocalFallback.prefix(limit)) }
            return Array(localCheckIns(employeeId: currentUserId).prefix(limit))
        }

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: predicate,
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)]
            )
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "fetchCheckIns")
            guard isRecoverableReadError(error) else {
                throw error
            }
            AppLog.warning("Check-in list fetch recovered for user=\(AppLog.redactIdentifier(currentUserId)): \(AppLog.sanitize(error.localizedDescription))")
            guard role != .manager else { return Array(managerLocalFallback.prefix(limit)) }
            return Array(localCheckIns(employeeId: currentUserId).prefix(limit))
        }

        let cloudCheckIns = records.compactMap(decodeCheckIn(record:))
        guard role != .manager else {
            let merged = mergeCheckIns(preferred: cloudCheckIns, fallback: managerLocalFallback)
            return Array(merged.prefix(limit))
        }
        let merged = mergeCheckIns(preferred: cloudCheckIns, fallback: localCheckIns(employeeId: currentUserId))
        return Array(merged.prefix(limit))
    }

    func fetchEmployeeCheckIns(employeeId: String, limit: Int) async throws -> [CheckIn] {
        if isLocalOnlyModeEnabled {
            return Array(localCheckIns(employeeId: employeeId).prefix(limit))
        }

        try await service.ensureCloudKitAvailable()

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, employeeId),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)]
            )
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "fetchEmployeeCheckIns")
            guard isRecoverableReadError(error) else {
                throw error
            }
            AppLog.warning("Employee check-in fetch recovered for user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))")
            return Array(localCheckIns(employeeId: employeeId).prefix(limit))
        }

        let cloudCheckIns = records.compactMap(decodeCheckIn(record:))
        let merged = mergeCheckIns(preferred: cloudCheckIns, fallback: localCheckIns(employeeId: employeeId))
        return Array(merged.prefix(limit))
    }

    func fetchManagerStoreCheckIns(
        managerId: String,
        storeId: String,
        fromDate: Date,
        toDate: Date,
        employeeId: String?,
        limit: Int
    ) async throws -> [CheckIn] {
        let currentUserId = try service.requireCurrentUserId()
        guard managerId == currentUserId else {
            throw CloudKitClientError.unauthorized
        }

        let localFallback = localManagerCheckIns(
            managerId: managerId,
            storeId: storeId,
            fromDate: fromDate,
            toDate: toDate,
            employeeId: employeeId,
            status: nil
        )

        if isLocalOnlyModeEnabled {
            return Array(localFallback.prefix(limit))
        }

        try await service.ensureCloudKitAvailable()

        var predicates: [NSPredicate] = [
            NSPredicate(format: "%K == %@", CKSchema.CheckInField.managerUserId, managerId),
            NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, storeId),
            NSPredicate(format: "%K >= %@", CKSchema.CheckInField.checkInAt, fromDate as NSDate),
            NSPredicate(format: "%K < %@", CKSchema.CheckInField.checkInAt, toDate as NSDate)
        ]

        if let employeeId, !employeeId.isEmpty {
            predicates.append(NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, employeeId))
        }

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)]
            )
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "fetchManagerStoreCheckIns")
            guard isRecoverableReadError(error) else {
                throw error
            }
            AppLog.warning("Manager store check-in fetch recovered manager=\(AppLog.redactIdentifier(managerId)) store=\(storeId): \(AppLog.sanitize(error.localizedDescription))")
            return Array(localFallback.prefix(limit))
        }

        let cloudCheckIns = records.compactMap(decodeCheckIn(record:))
        let merged = mergeCheckIns(preferred: cloudCheckIns, fallback: localFallback)
        return Array(merged.prefix(limit))
    }

    func fetchTodaysCheckIns(filter: CheckInFilter) async throws -> [CheckIn] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: filter.date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()

        let currentUserId = try service.requireCurrentUserId()
        let role = service.currentRole

        var predicates: [NSPredicate] = [
            NSPredicate(format: "%K >= %@", CKSchema.CheckInField.checkInAt, start as NSDate),
            NSPredicate(format: "%K < %@", CKSchema.CheckInField.checkInAt, end as NSDate)
        ]

        if role == .manager {
            predicates.append(NSPredicate(format: "%K == %@", CKSchema.CheckInField.managerUserId, currentUserId))
        } else {
            predicates.append(NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, currentUserId))
        }

        if let storeId = filter.storeId, !storeId.isEmpty {
            predicates.append(NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, storeId))
        }

        if let status = filter.status {
            predicates.append(NSPredicate(format: "%K == %@", CKSchema.CheckInField.status, status.rawValue))
        }

        let managerLocalFallback: [CheckIn]
        if role == .manager {
            managerLocalFallback = localManagerCheckIns(
                managerId: currentUserId,
                storeId: filter.storeId,
                fromDate: start,
                toDate: end,
                employeeId: nil,
                status: filter.status
            )
        } else {
            managerLocalFallback = []
        }

        if isLocalOnlyModeEnabled {
            guard role != .manager else { return managerLocalFallback }
            return localTodaysCheckIns(employeeId: currentUserId, filter: filter)
        }

        try await service.ensureCloudKitAvailable()

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)]
            )
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "fetchTodaysCheckIns")
            guard isRecoverableReadError(error) else {
                throw error
            }
            AppLog.warning("Today's check-in fetch recovered for user=\(AppLog.redactIdentifier(currentUserId)): \(AppLog.sanitize(error.localizedDescription))")
            guard role != .manager else { return managerLocalFallback }
            return localTodaysCheckIns(employeeId: currentUserId, filter: filter)
        }

        let cloudCheckIns = records.compactMap(decodeCheckIn(record:))
        guard role != .manager else {
            return mergeCheckIns(preferred: cloudCheckIns, fallback: managerLocalFallback)
        }
        return mergeCheckIns(
            preferred: cloudCheckIns,
            fallback: localTodaysCheckIns(employeeId: currentUserId, filter: filter)
        )
    }

    func fetchVerificationPhotoData(checkInId: String, storeId: String) async throws -> Data? {
        if let localData = localPhotoData(checkInId: checkInId, kind: .checkIn) {
            return localData
        }

        if isLocalOnlyModeEnabled {
            return nil
        }

        let recordID = CloudKitService.checkInRecordID(checkInId: checkInId)
        do {
            guard let record = try await service.fetchRecord(with: recordID) else {
                return nil
            }
            if let recordStoreId = record.string(CKSchema.CheckInField.storeId), !storeId.isEmpty, recordStoreId != storeId {
                return nil
            }
            guard let asset = record[CKSchema.CheckInField.checkInPhotoAsset] as? CKAsset,
                  let fileURL = asset.fileURL else {
                return nil
            }
            return try Data(contentsOf: fileURL)
        } catch {
            enableLocalOnlyModeIfNeeded(for: error, context: "fetchVerificationPhotoData")
            guard shouldUseLocalReadFallback(for: error) else {
                throw error
            }
            return nil
        }
    }

    func fetchVerificationPhotoURL(photoPath: String) async throws -> URL {
        if let localURL = localPhotoURL(forToken: photoPath) {
            return localURL
        }

        let url = URL(fileURLWithPath: photoPath)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        throw CloudKitClientError.missingRecord("Photo proof is unavailable.")
    }

    private func fetchActiveSessions(employeeId: String, storeId: String) async throws -> [CheckIn] {
        let records = try await service.queryRecords(
            recordType: CKSchema.RecordType.checkInSession,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, employeeId),
                NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, storeId)
            ]),
            sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)]
        )

        return records.compactMap(decodeCheckIn(record:)).filter { $0.checkOutTime == nil }
    }

    private func ensureActiveMembership(employeeId: String, storeId: String) async throws {
        let membershipRecordID = CloudKitService.membershipRecordID(storeId: storeId, employeeId: employeeId)
        guard let membership = try await service.fetchRecord(with: membershipRecordID) else {
            throw CloudKitClientError.invalidData("You are no longer a member of this store.")
        }

        let status = membership.string(CKSchema.StoreMemberField.status)
        guard status == CKSchema.MemberStatus.active else {
            throw CloudKitClientError.invalidData("You are no longer a member of this store.")
        }

        guard let storeRecord = try await service.fetchRecord(with: CloudKitService.storeRecordID(storeId: storeId)),
              storeRecord.bool(CKSchema.StoreField.isActive, default: true) else {
            throw CloudKitClientError.invalidData("This store is no longer active.")
        }
    }

    private func isRecoverableReadError(_ error: Error) -> Bool {
        if shouldUseLocalReadFallback(for: error) {
            return true
        }

        if let clientError = error as? CloudKitClientError,
           case .unauthorized = clientError {
            return true
        }

        if let ckError = error as? CKError {
            switch ckError.code {
            case .permissionFailure, .unknownItem, .invalidArguments, .serverRejectedRequest, .partialFailure:
                return true
            default:
                break
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("record type") ||
            description.contains("schema") ||
            description.contains("unknown field")
    }

    private func shouldUseLocalReadFallback(for error: Error) -> Bool {
        if let clientError = error as? CloudKitClientError,
           case .invalidData(let message) = clientError,
           message.localizedCaseInsensitiveContains("invalid bundle id for container") {
            return true
        }

        if let ckError = error as? CKError,
           ckError.code == .permissionFailure,
           ckError.localizedDescription.localizedCaseInsensitiveContains("invalid bundle id for container") {
            return true
        }

        return error.localizedDescription.localizedCaseInsensitiveContains("invalid bundle id for container")
    }

    private func enableLocalOnlyModeIfNeeded(for error: Error, context: String) {
        if service.isCloudKitIdentityMismatchDetected {
            isCloudKitIdentityMismatchDetected = true
            return
        }
        guard shouldUseLocalReadFallback(for: error) else {
            return
        }
        guard !isCloudKitIdentityMismatchDetected else {
            return
        }
        isCloudKitIdentityMismatchDetected = true
        AppLog.warning("Check-in repository switched to local-only mode context=\(context)")
    }

    private struct LocalCheckInPayload: Codable {
        var checkInsByEmployeeId: [String: [CheckIn]] = [:]
    }

    private enum LocalPhotoKind: String {
        case checkIn = "checkin"
        case checkOut = "checkout"
    }

    private struct LocalManagerStorePayload: Codable {
        var storesByManagerId: [String: [Store]] = [:]
    }

    private func localCheckIns(employeeId: String) -> [CheckIn] {
        let payload = loadLocalCheckInPayload()
        return (payload.checkInsByEmployeeId[employeeId] ?? [])
            .sorted { $0.checkInTime > $1.checkInTime }
    }

    private func mergeCheckIns(preferred: [CheckIn], fallback: [CheckIn]) -> [CheckIn] {
        var mergedByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        for checkIn in preferred {
            mergedByID[checkIn.id] = checkIn
        }
        return mergedByID.values.sorted { $0.checkInTime > $1.checkInTime }
    }

    private func localTodaysCheckIns(employeeId: String, filter: CheckInFilter) -> [CheckIn] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: filter.date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()

        return localCheckIns(employeeId: employeeId).filter { item in
            guard item.checkInTime >= start, item.checkInTime < end else { return false }
            if let storeId = filter.storeId, !storeId.isEmpty, item.storeId != storeId {
                return false
            }
            if let status = filter.status, item.status != status {
                return false
            }
            return true
        }
    }

    private func localManagerCheckIns(
        managerId: String,
        storeId: String? = nil,
        fromDate: Date? = nil,
        toDate: Date? = nil,
        employeeId: String? = nil,
        status: CheckInStatus? = nil
    ) -> [CheckIn] {
        let managedStoreIDs = localManagerStoreIDs(managerId: managerId)
        guard !managedStoreIDs.isEmpty else { return [] }

        let payload = loadLocalCheckInPayload()
        let allLocal = payload.checkInsByEmployeeId.values.flatMap { $0 }
        return allLocal
            .filter { item in
                guard managedStoreIDs.contains(item.storeId) else { return false }
                if let storeId, !storeId.isEmpty, item.storeId != storeId {
                    return false
                }
                if let fromDate, item.checkInTime < fromDate {
                    return false
                }
                if let toDate, item.checkInTime >= toDate {
                    return false
                }
                if let employeeId, !employeeId.isEmpty, item.employeeId != employeeId {
                    return false
                }
                if let status, item.status != status {
                    return false
                }
                return true
            }
            .sorted { $0.checkInTime > $1.checkInTime }
    }

    private func persistLocalCheckIn(_ checkIn: CheckIn, employeeId: String, checkInPhotoData: Data) throws {
        var payload = loadLocalCheckInPayload()
        var sessions = payload.checkInsByEmployeeId[employeeId] ?? []

        guard sessions.first(where: { $0.storeId == checkIn.storeId && $0.checkOutTime == nil && $0.id != checkIn.id }) == nil else {
            throw CloudKitClientError.invalidData("You already have an active check-in for this store.")
        }

        var localCheckIn = checkIn
        let now = Date()
        localCheckIn.createdAt = localCheckIn.createdAt ?? now
        localCheckIn.updatedAt = now
        localCheckIn.checkInPhotoAssetID = try persistLocalPhotoData(
            checkInPhotoData,
            checkInId: localCheckIn.id,
            kind: .checkIn
        )

        if let index = sessions.firstIndex(where: { $0.id == localCheckIn.id }) {
            sessions[index] = localCheckIn
        } else {
            sessions.append(localCheckIn)
        }

        payload.checkInsByEmployeeId[employeeId] = sessions.sorted { $0.checkInTime > $1.checkInTime }
        saveLocalCheckInPayload(payload)
    }

    private func checkoutLocalCheckIn(
        checkinId: String,
        storeId: String,
        employeeId: String,
        checkoutLat: Double,
        checkoutLng: Double,
        distanceMeters: Double,
        accuracyMeters: Double,
        verification: Verify2ReadEvidence,
        checkOutPhotoData: Data
    ) throws {
        var payload = loadLocalCheckInPayload()
        var sessions = payload.checkInsByEmployeeId[employeeId] ?? []
        guard let index = sessions.firstIndex(where: { $0.id == checkinId }) else {
            throw CloudKitClientError.missingRecord("Check-in session not found.")
        }
        guard sessions[index].storeId == storeId else {
            throw CloudKitClientError.invalidData("Session store mismatch.")
        }
        guard sessions[index].checkOutTime == nil else {
            throw CloudKitClientError.invalidData("This session is already checked out.")
        }

        let checkoutTime = Date()
        let durationSeconds = max(Int(checkoutTime.timeIntervalSince(sessions[index].checkInTime)), 0)
        sessions[index].checkOutTime = checkoutTime
        sessions[index].checkOutLat = checkoutLat
        sessions[index].checkOutLng = checkoutLng
        sessions[index].checkOutDistanceMeters = distanceMeters
        sessions[index].checkOutAccuracyMeters = accuracyMeters
        sessions[index].durationSeconds = durationSeconds
        sessions[index].verifyMethod = verification.method
        sessions[index].verifyVersion = verification.version
        sessions[index].verifyOutInside = verification.inside
        sessions[index].verifyOutDistance1Meters = verification.distance1Meters
        sessions[index].verifyOutDistance2Meters = verification.distance2Meters
        sessions[index].verifyOutDriftMeters = verification.driftMeters
        sessions[index].verifyOutRead1At = verification.read1At
        sessions[index].verifyOutRead2At = verification.read2At
        sessions[index].verifyOutAccuracy1Meters = verification.read1Accuracy
        sessions[index].verifyOutAccuracy2Meters = verification.read2Accuracy
        sessions[index].updatedAt = Date()
        sessions[index].checkOutPhotoAssetID = try persistLocalPhotoData(
            checkOutPhotoData,
            checkInId: checkinId,
            kind: .checkOut
        )

        payload.checkInsByEmployeeId[employeeId] = sessions.sorted { $0.checkInTime > $1.checkInTime }
        saveLocalCheckInPayload(payload)
    }

    private func loadLocalCheckInPayload() -> LocalCheckInPayload {
        guard let data = UserDefaults.standard.data(forKey: Self.localCheckInsKey) else {
            return LocalCheckInPayload()
        }
        do {
            return try JSONDecoder().decode(LocalCheckInPayload.self, from: data)
        } catch {
            AppLog.warning("Local check-in fallback decode failed: \(AppLog.sanitize(error.localizedDescription))")
            return LocalCheckInPayload()
        }
    }

    private func saveLocalCheckInPayload(_ payload: LocalCheckInPayload) {
        do {
            let data = try JSONEncoder().encode(payload)
            UserDefaults.standard.set(data, forKey: Self.localCheckInsKey)
        } catch {
            AppLog.warning("Local check-in fallback encode failed: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func clearLocalCheckInsForEmployee(employeeId: String) {
        var payload = loadLocalCheckInPayload()
        payload.checkInsByEmployeeId[employeeId] = []
        saveLocalCheckInPayload(payload)
    }

    private func clearLocalCheckInsForStore(managerId: String, storeId: String) {
        _ = managerId

        var payload = loadLocalCheckInPayload()
        for (employeeId, sessions) in payload.checkInsByEmployeeId {
            let filtered = sessions.filter { $0.storeId != storeId }
            payload.checkInsByEmployeeId[employeeId] = filtered
        }
        saveLocalCheckInPayload(payload)
    }

    private func updateLocalCheckIn(
        checkInId: String,
        managerId: String,
        mutate: (inout CheckIn) -> Void
    ) throws {
        _ = managerId
        var payload = loadLocalCheckInPayload()

        var updated = false
        for (employeeId, sessions) in payload.checkInsByEmployeeId {
            var mutableSessions = sessions
            guard let index = mutableSessions.firstIndex(where: { $0.id == checkInId }) else {
                continue
            }

            mutate(&mutableSessions[index])
            mutableSessions[index].updatedAt = Date()
            payload.checkInsByEmployeeId[employeeId] = mutableSessions.sorted { $0.checkInTime > $1.checkInTime }
            updated = true
            break
        }

        guard updated else {
            throw CloudKitClientError.missingRecord("Check-in session not found.")
        }

        saveLocalCheckInPayload(payload)
    }

    private func persistLocalPhotoData(_ data: Data, checkInId: String, kind: LocalPhotoKind) throws -> String {
        let token = "\(kind.rawValue)_\(checkInId).jpg"
        let url = localPhotoFileURL(token: token)
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        try data.write(to: url, options: .atomic)
        return token
    }

    private func localPhotoData(checkInId: String, kind: LocalPhotoKind) -> Data? {
        let token = "\(kind.rawValue)_\(checkInId).jpg"
        let url = localPhotoFileURL(token: token)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private func localPhotoURL(forToken token: String) -> URL? {
        let url = localPhotoFileURL(token: token)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func localPhotoFileURL(token: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.localPhotoDirectoryName, isDirectory: true)
            .appendingPathComponent(token)
    }

    private func localManagerStoreIDs(managerId: String) -> Set<String> {
        let payload = loadLocalManagerStorePayload()
        let stores = payload.storesByManagerId[managerId] ?? []
        return Set(stores.filter(\.isActive).map(\.id))
    }

    private func loadLocalManagerStorePayload() -> LocalManagerStorePayload {
        guard let data = UserDefaults.standard.data(forKey: Self.localManagerStoresKey) else {
            return LocalManagerStorePayload()
        }
        do {
            return try JSONDecoder().decode(LocalManagerStorePayload.self, from: data)
        } catch {
            AppLog.warning("Local manager store fallback decode failed: \(AppLog.sanitize(error.localizedDescription))")
            return LocalManagerStorePayload()
        }
    }

    private func decodeCheckIn(record: CKRecord) -> CheckIn? {
        guard let id = record.string(CKSchema.CheckInField.sessionId),
              let employeeId = record.string(CKSchema.CheckInField.employeeUserId),
              let storeId = record.string(CKSchema.CheckInField.storeId),
              let checkInTime = record.date(CKSchema.CheckInField.checkInAt) else {
            return nil
        }

        let statusRaw = record.string(CKSchema.CheckInField.status) ?? CheckInStatus.approved.rawValue
        let status = CheckInStatus(rawValue: statusRaw) ?? .approved

        return CheckIn(
            id: id,
            employeeId: employeeId,
            storeId: storeId,
            checkInTime: checkInTime,
            checkOutTime: record.date(CKSchema.CheckInField.checkOutAt),
            clientLat: (record[CKSchema.CheckInField.checkInLocationLat] as? NSNumber)?.doubleValue ?? 0,
            clientLng: (record[CKSchema.CheckInField.checkInLocationLng] as? NSNumber)?.doubleValue ?? 0,
            distanceMeters: (record[CKSchema.CheckInField.checkInDistanceMeters] as? NSNumber)?.doubleValue ?? 0,
            accuracyMeters: (record[CKSchema.CheckInField.checkInAccuracyMeters] as? NSNumber)?.doubleValue ?? 0,
            checkOutLat: (record[CKSchema.CheckInField.checkOutLocationLat] as? NSNumber)?.doubleValue,
            checkOutLng: (record[CKSchema.CheckInField.checkOutLocationLng] as? NSNumber)?.doubleValue,
            checkOutDistanceMeters: (record[CKSchema.CheckInField.checkOutDistanceMeters] as? NSNumber)?.doubleValue,
            checkOutAccuracyMeters: (record[CKSchema.CheckInField.checkOutAccuracyMeters] as? NSNumber)?.doubleValue,
            durationSeconds: (record[CKSchema.CheckInField.durationSeconds] as? NSNumber)?.intValue,
            status: status,
            rejectReason: record.string(CKSchema.CheckInField.rejectReason),
            employeeName: record.string(CKSchema.CheckInField.employeeName) ?? "Employee",
            employeeEmail: record.string(CKSchema.CheckInField.employeeEmail),
            storeName: record.string(CKSchema.CheckInField.storeName) ?? "Store",
            verifyVersion: (record[CKSchema.CheckInField.verifyVersion] as? NSNumber)?.intValue,
            verifyMethod: record.string(CKSchema.CheckInField.verifyMethod),
            verifyInInside: (record[CKSchema.CheckInField.verifyInInside] as? NSNumber)?.boolValue,
            verifyInDistance1Meters: (record[CKSchema.CheckInField.verifyInDistance1Meters] as? NSNumber)?.doubleValue,
            verifyInDistance2Meters: (record[CKSchema.CheckInField.verifyInDistance2Meters] as? NSNumber)?.doubleValue,
            verifyInDriftMeters: (record[CKSchema.CheckInField.verifyInDriftMeters] as? NSNumber)?.doubleValue,
            verifyInRead1At: record.date(CKSchema.CheckInField.verifyInRead1At),
            verifyInRead2At: record.date(CKSchema.CheckInField.verifyInRead2At),
            verifyInAccuracy1Meters: (record[CKSchema.CheckInField.verifyInAccuracy1Meters] as? NSNumber)?.doubleValue,
            verifyInAccuracy2Meters: (record[CKSchema.CheckInField.verifyInAccuracy2Meters] as? NSNumber)?.doubleValue,
            verifyOutInside: (record[CKSchema.CheckInField.verifyOutInside] as? NSNumber)?.boolValue,
            verifyOutDistance1Meters: (record[CKSchema.CheckInField.verifyOutDistance1Meters] as? NSNumber)?.doubleValue,
            verifyOutDistance2Meters: (record[CKSchema.CheckInField.verifyOutDistance2Meters] as? NSNumber)?.doubleValue,
            verifyOutDriftMeters: (record[CKSchema.CheckInField.verifyOutDriftMeters] as? NSNumber)?.doubleValue,
            verifyOutRead1At: record.date(CKSchema.CheckInField.verifyOutRead1At),
            verifyOutRead2At: record.date(CKSchema.CheckInField.verifyOutRead2At),
            verifyOutAccuracy1Meters: (record[CKSchema.CheckInField.verifyOutAccuracy1Meters] as? NSNumber)?.doubleValue,
            verifyOutAccuracy2Meters: (record[CKSchema.CheckInField.verifyOutAccuracy2Meters] as? NSNumber)?.doubleValue,
            checkInPhotoAssetID: (record[CKSchema.CheckInField.checkInPhotoAsset] as? CKAsset)?.fileURL?.lastPathComponent,
            checkOutPhotoAssetID: (record[CKSchema.CheckInField.checkOutPhotoAsset] as? CKAsset)?.fileURL?.lastPathComponent,
            createdAt: record.date(CKSchema.CheckInField.createdAt),
            updatedAt: record.date(CKSchema.CheckInField.updatedAt)
        )
    }

    private func encodeVerificationIn(record: CKRecord, from checkIn: CheckIn) {
        if let verifyVersion = checkIn.verifyVersion {
            record[CKSchema.CheckInField.verifyVersion] = NSNumber(value: verifyVersion)
        }
        if let verifyMethod = checkIn.verifyMethod {
            record[CKSchema.CheckInField.verifyMethod] = verifyMethod as CKRecordValue
        }
        if let verifyInInside = checkIn.verifyInInside {
            record[CKSchema.CheckInField.verifyInInside] = NSNumber(value: verifyInInside)
        }
        if let verifyInDistance1Meters = checkIn.verifyInDistance1Meters {
            record[CKSchema.CheckInField.verifyInDistance1Meters] = NSNumber(value: verifyInDistance1Meters)
        }
        if let verifyInDistance2Meters = checkIn.verifyInDistance2Meters {
            record[CKSchema.CheckInField.verifyInDistance2Meters] = NSNumber(value: verifyInDistance2Meters)
        }
        if let verifyInDriftMeters = checkIn.verifyInDriftMeters {
            record[CKSchema.CheckInField.verifyInDriftMeters] = NSNumber(value: verifyInDriftMeters)
        }
        if let verifyInRead1At = checkIn.verifyInRead1At {
            record[CKSchema.CheckInField.verifyInRead1At] = verifyInRead1At as CKRecordValue
        }
        if let verifyInRead2At = checkIn.verifyInRead2At {
            record[CKSchema.CheckInField.verifyInRead2At] = verifyInRead2At as CKRecordValue
        }
        if let verifyInAccuracy1Meters = checkIn.verifyInAccuracy1Meters {
            record[CKSchema.CheckInField.verifyInAccuracy1Meters] = NSNumber(value: verifyInAccuracy1Meters)
        }
        if let verifyInAccuracy2Meters = checkIn.verifyInAccuracy2Meters {
            record[CKSchema.CheckInField.verifyInAccuracy2Meters] = NSNumber(value: verifyInAccuracy2Meters)
        }
    }

    private func makeTemporaryAssetFile(data: Data, prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix)
            .appendingPathExtension("jpg")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func signature(for checkIns: [CheckIn]) -> String {
        checkIns
            .map { item in
                let updated = item.updatedAt?.timeIntervalSince1970 ?? item.checkInTime.timeIntervalSince1970
                return "\(item.id):\(updated):\(item.checkOutTime?.timeIntervalSince1970 ?? 0):\(item.status.rawValue)"
            }
            .joined(separator: "|")
    }
}
