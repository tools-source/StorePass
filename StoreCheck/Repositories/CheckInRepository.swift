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

    init(service: CloudKitService, userProfileStore: UserProfileStoreProtocol) {
        self.service = service
        self.userProfileStore = userProfileStore
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
        try await service.ensureCloudKitAvailable()

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
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        guard !checkOutPhotoData.isEmpty else {
            throw CloudKitClientError.invalidData("A photo is required to check out.")
        }

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
    }

    func updateCheckIn(_ checkIn: CheckIn) async throws {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
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
    }

    func updateCheckInTimes(checkIn: CheckIn, newCheckInTime: Date, newCheckOutTime: Date?) async throws {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
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
        let predicate = NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, currentUserId)
        let records = try await service.queryRecords(recordType: CKSchema.RecordType.checkInSession, predicate: predicate)
        let recordIds = records.map(\.recordID)
        if !recordIds.isEmpty {
            _ = try await service.modify(recordsToSave: [], recordIDsToDelete: recordIds, atomic: false)
        }
    }

    func clearAllCheckIns(storeId: String, managerId: String, limit: Int) async throws {
        _ = limit

        let currentUserId = try service.requireCurrentUserId()
        guard currentUserId == managerId else {
            throw CloudKitClientError.unauthorized
        }

        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K == %@", CKSchema.CheckInField.managerUserId, managerId),
            NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, storeId)
        ])

        let records = try await service.queryRecords(recordType: CKSchema.RecordType.checkInSession, predicate: predicate)
        let recordIds = records.map(\.recordID)
        if !recordIds.isEmpty {
            _ = try await service.modify(recordsToSave: [], recordIDsToDelete: recordIds, atomic: false)
        }
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

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: predicate,
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)]
            )
        } catch {
            guard isRecoverableReadError(error) else {
                throw error
            }
            AppLog.warning("Check-in list fetch recovered for user=\(AppLog.redactIdentifier(currentUserId)): \(AppLog.sanitize(error.localizedDescription))")
            return []
        }

        return Array(records.compactMap(decodeCheckIn(record:)).prefix(limit))
    }

    func fetchEmployeeCheckIns(employeeId: String, limit: Int) async throws -> [CheckIn] {
        try await service.ensureCloudKitAvailable()

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, employeeId),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)]
            )
        } catch {
            guard isRecoverableReadError(error) else {
                throw error
            }
            AppLog.warning("Employee check-in fetch recovered for user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))")
            return []
        }

        return Array(records.compactMap(decodeCheckIn(record:)).prefix(limit))
    }

    func fetchManagerStoreCheckIns(
        managerId: String,
        storeId: String,
        fromDate: Date,
        toDate: Date,
        employeeId: String?,
        limit: Int
    ) async throws -> [CheckIn] {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        guard managerId == currentUserId else {
            throw CloudKitClientError.unauthorized
        }

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
            guard isRecoverableReadError(error) else {
                throw error
            }
            AppLog.warning("Manager store check-in fetch recovered manager=\(AppLog.redactIdentifier(managerId)) store=\(storeId): \(AppLog.sanitize(error.localizedDescription))")
            return []
        }

        return Array(records.compactMap(decodeCheckIn(record:)).prefix(limit))
    }

    func fetchTodaysCheckIns(filter: CheckInFilter) async throws -> [CheckIn] {
        try await service.ensureCloudKitAvailable()

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

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: predicates),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)]
            )
        } catch {
            guard isRecoverableReadError(error) else {
                throw error
            }
            AppLog.warning("Today's check-in fetch recovered for user=\(AppLog.redactIdentifier(currentUserId)): \(AppLog.sanitize(error.localizedDescription))")
            return []
        }

        return records.compactMap(decodeCheckIn(record:))
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
