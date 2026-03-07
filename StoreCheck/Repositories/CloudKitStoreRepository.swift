import CloudKit
import Foundation

@MainActor
final class CloudKitStoreRepository: StoreRepositoryProtocol {
    private let service: CloudKitService

    init(service: CloudKitService) {
        self.service = service
    }

    func fetchStores(ids: [String]?) async throws -> [Store] {
        try await service.ensureCloudKitAvailable()

        if let ids {
            if ids.isEmpty { return [] }
            var fetched: [Store] = []
            for id in ids {
                let recordID = CloudKitService.storeRecordID(storeId: id)
                guard let record = try await service.fetchRecord(with: recordID),
                      let store = decodeStore(record: record),
                      store.isActive else {
                    continue
                }
                fetched.append(store)
            }
            return fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        guard let userId = service.currentUserId else {
            throw CloudKitClientError.signedOut
        }

        if service.currentRole == .manager {
            return try await fetchManagerStores(managerId: userId)
        }

        let memberships = try await service.queryRecords(
            recordType: CKSchema.RecordType.storeMember,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.employeeUserId, userId),
                NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.status, CKSchema.MemberStatus.active)
            ])
        )

        let storeIds = memberships.compactMap { $0.string(CKSchema.StoreMemberField.storeId) }
        return try await fetchStores(ids: Array(Set(storeIds)))
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        try await service.ensureCloudKitAvailable()

        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K == %@", CKSchema.StoreField.managerUserId, managerId),
            NSPredicate(format: "%K == %@", CKSchema.StoreField.isActive, NSNumber(value: true))
        ])

        let records = try await service.queryRecords(
            recordType: CKSchema.RecordType.store,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: CKSchema.StoreField.name, ascending: true)]
        )

        return records.compactMap(decodeStore(record:))
    }

    func upsertStore(_ store: Store) async throws {
        try await service.ensureCloudKitAvailable()

        guard let currentUserId = service.currentUserId else {
            throw CloudKitClientError.signedOut
        }

        let storeRecordID = CloudKitService.storeRecordID(storeId: store.id)
        guard let record = try await service.fetchRecord(with: storeRecordID) else {
            throw CloudKitClientError.missingRecord("Store not found.")
        }

        let managerId = record.string(CKSchema.StoreField.managerUserId)
        guard managerId == currentUserId else {
            throw CloudKitClientError.unauthorized
        }

        try validateStore(name: store.name, address: store.address, latitude: store.latitude, longitude: store.longitude, radiusMeters: store.radiusMeters)

        record[CKSchema.StoreField.name] = store.name.trimmingCharacters(in: .whitespacesAndNewlines) as CKRecordValue
        record[CKSchema.StoreField.address] = store.address.trimmingCharacters(in: .whitespacesAndNewlines) as CKRecordValue
        record[CKSchema.StoreField.latitude] = NSNumber(value: store.latitude)
        record[CKSchema.StoreField.longitude] = NSNumber(value: store.longitude)
        record[CKSchema.StoreField.radiusMeters] = NSNumber(value: store.radiusMeters)
        record[CKSchema.StoreField.isActive] = NSNumber(value: store.isActive)
        record[CKSchema.StoreField.updatedAt] = Date() as CKRecordValue

        _ = try await service.save(record: record)
    }

    func deleteStore(id: String) async throws {
        try await service.ensureCloudKitAvailable()
        let currentUserId = try service.requireCurrentUserId()

        let storeRecordID = CloudKitService.storeRecordID(storeId: id)
        guard let storeRecord = try await service.fetchRecord(with: storeRecordID) else {
            return
        }

        guard storeRecord.string(CKSchema.StoreField.managerUserId) == currentUserId else {
            throw CloudKitClientError.unauthorized
        }

        let now = Date()
        storeRecord[CKSchema.StoreField.isActive] = NSNumber(value: false)
        storeRecord[CKSchema.StoreField.updatedAt] = now as CKRecordValue
        storeRecord[CKSchema.StoreField.deletedAt] = now as CKRecordValue

        let memberships = try await service.queryRecords(
            recordType: CKSchema.RecordType.storeMember,
            predicate: NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.storeId, id)
        )

        var employeeIds = Set<String>()
        var recordsToSave: [CKRecord] = [storeRecord]

        for membership in memberships {
            membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.removed as CKRecordValue
            membership[CKSchema.StoreMemberField.updatedAt] = now as CKRecordValue
            if let employeeId = membership.string(CKSchema.StoreMemberField.employeeUserId) {
                employeeIds.insert(employeeId)
            }
            recordsToSave.append(membership)
        }

        _ = try await service.modify(recordsToSave: recordsToSave)

        for employeeId in employeeIds {
            try await recomputeAssignedStores(for: employeeId)
        }
    }

    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async throws -> StoreCreationResult {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        try validateStore(name: name, address: address, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)

        let managerRecordID = CloudKitService.userRecordID(userId: currentUserId)
        guard let managerRecord = try await service.fetchRecord(with: managerRecordID),
              managerRecord.bool(CKSchema.UserField.isActive, default: true) else {
            throw CloudKitClientError.missingRecord("Manager profile is unavailable.")
        }

        let storeId = UUID().uuidString
        let joinCode = Self.generateJoinCode()
        let joinCodeHash = CloudKitService.stableHash(normalizeJoinCode(joinCode))
        let now = Date()

        let storeRecordID = CloudKitService.storeRecordID(storeId: storeId)
        let record = CKRecord(recordType: CKSchema.RecordType.store, recordID: storeRecordID)
        record[CKSchema.StoreField.storeId] = storeId as CKRecordValue
        record[CKSchema.StoreField.managerUserId] = currentUserId as CKRecordValue
        record[CKSchema.StoreField.managerUserRef] = CKRecord.Reference(recordID: managerRecordID, action: .none)
        record[CKSchema.StoreField.name] = name.trimmingCharacters(in: .whitespacesAndNewlines) as CKRecordValue
        record[CKSchema.StoreField.address] = address.trimmingCharacters(in: .whitespacesAndNewlines) as CKRecordValue
        record[CKSchema.StoreField.latitude] = NSNumber(value: latitude)
        record[CKSchema.StoreField.longitude] = NSNumber(value: longitude)
        record[CKSchema.StoreField.radiusMeters] = NSNumber(value: radiusMeters)
        record[CKSchema.StoreField.joinCode] = joinCode as CKRecordValue
        record[CKSchema.StoreField.joinCodeHash] = joinCodeHash as CKRecordValue
        record[CKSchema.StoreField.joinCodeLast4] = String(joinCode.suffix(4)) as CKRecordValue
        record[CKSchema.StoreField.isActive] = NSNumber(value: true)
        record[CKSchema.StoreField.createdAt] = now as CKRecordValue
        record[CKSchema.StoreField.updatedAt] = now as CKRecordValue

        _ = try await service.save(record: record)

        let store = Store(
            id: storeId,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            isActive: true,
            managerId: currentUserId,
            createdAt: now,
            updatedAt: now,
            joinCode: joinCode,
            joinCodeCiphertext: joinCode,
            joinCodeLast4: String(joinCode.suffix(4))
        )

        return StoreCreationResult(store: store, joinCode: joinCode)
    }

    func rotateStoreCode(storeId: String) async throws -> String {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        let storeRecordID = CloudKitService.storeRecordID(storeId: storeId)
        guard let record = try await service.fetchRecord(with: storeRecordID) else {
            throw CloudKitClientError.missingRecord("Store not found.")
        }

        guard record.string(CKSchema.StoreField.managerUserId) == currentUserId else {
            throw CloudKitClientError.unauthorized
        }

        let newCode = Self.generateJoinCode()
        record[CKSchema.StoreField.joinCode] = newCode as CKRecordValue
        record[CKSchema.StoreField.joinCodeHash] = CloudKitService.stableHash(normalizeJoinCode(newCode)) as CKRecordValue
        record[CKSchema.StoreField.joinCodeLast4] = String(newCode.suffix(4)) as CKRecordValue
        record[CKSchema.StoreField.updatedAt] = Date() as CKRecordValue

        _ = try await service.save(record: record)
        return newCode
    }

    func getStoreJoinCode(storeId: String) async throws -> String {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        let storeRecordID = CloudKitService.storeRecordID(storeId: storeId)
        guard let record = try await service.fetchRecord(with: storeRecordID) else {
            throw CloudKitClientError.missingRecord("Store not found.")
        }

        guard record.string(CKSchema.StoreField.managerUserId) == currentUserId else {
            throw CloudKitClientError.unauthorized
        }

        if let existing = record.string(CKSchema.StoreField.joinCode), !existing.isEmpty {
            return existing
        }

        return try await rotateStoreCode(storeId: storeId)
    }

    func joinStoreByCode(code: String) async throws -> JoinStoreResult {
        try await service.ensureCloudKitAvailable()

        let normalizedCode = normalizeJoinCode(code)
        guard normalizedCode.count >= 6 else {
            throw CloudKitClientError.invalidData("Enter a valid join code.")
        }

        let currentUserId = try service.requireCurrentUserId()
        let userRecordID = CloudKitService.userRecordID(userId: currentUserId)
        guard let userRecord = try await service.fetchRecord(with: userRecordID),
              let userProfile = decodeUserProfile(record: userRecord) else {
            throw CloudKitClientError.missingRecord("Your profile is missing. Sign in again.")
        }

        guard userProfile.role == .employee else {
            throw CloudKitClientError.invalidData("Only employees can join stores by code.")
        }

        guard userProfile.isActive else {
            throw CloudKitClientError.invalidData("Your account is inactive. Contact your manager.")
        }

        let codeHash = CloudKitService.stableHash(normalizedCode)
        let storeRecords = try await service.queryRecords(
            recordType: CKSchema.RecordType.store,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", CKSchema.StoreField.joinCodeHash, codeHash),
                NSPredicate(format: "%K == %@", CKSchema.StoreField.isActive, NSNumber(value: true))
            ]),
            sortDescriptors: [NSSortDescriptor(key: CKSchema.StoreField.updatedAt, ascending: false)]
        )

        guard let storeRecord = storeRecords.first,
              let store = decodeStore(record: storeRecord),
              store.isActive else {
            throw CloudKitClientError.invalidData("Join code not found. Ask your manager for a fresh code.")
        }

        let membershipRecordID = CloudKitService.membershipRecordID(storeId: store.id, employeeId: currentUserId)
        let membership = try await service.fetchRecord(with: membershipRecordID) ?? CKRecord(recordType: CKSchema.RecordType.storeMember, recordID: membershipRecordID)

        let alreadyJoined = membership.string(CKSchema.StoreMemberField.status) == CKSchema.MemberStatus.active

        membership[CKSchema.StoreMemberField.memberId] = membershipRecordID.recordName as CKRecordValue
        membership[CKSchema.StoreMemberField.storeId] = store.id as CKRecordValue
        membership[CKSchema.StoreMemberField.storeRef] = CKRecord.Reference(recordID: storeRecord.recordID, action: .none)
        membership[CKSchema.StoreMemberField.employeeUserId] = currentUserId as CKRecordValue
        membership[CKSchema.StoreMemberField.employeeUserRef] = CKRecord.Reference(recordID: userRecordID, action: .none)
        membership[CKSchema.StoreMemberField.employeeName] = userProfile.name as CKRecordValue
        if let email = userProfile.email, !email.isEmpty {
            membership[CKSchema.StoreMemberField.employeeEmail] = email as CKRecordValue
        }
        membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.active as CKRecordValue
        if membership.date(CKSchema.StoreMemberField.joinedAt) == nil {
            membership[CKSchema.StoreMemberField.joinedAt] = Date() as CKRecordValue
        }
        membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue

        var assignedStoreIds = Set(userProfile.assignedStoreIds)
        assignedStoreIds.insert(store.id)
        userRecord[CKSchema.UserField.assignedStoreIds] = Array(assignedStoreIds).sorted() as CKRecordValue
        userRecord[CKSchema.UserField.updatedAt] = Date() as CKRecordValue

        _ = try await service.modify(recordsToSave: [membership, userRecord])

        return JoinStoreResult(
            storeId: store.id,
            storeName: store.name,
            alreadyJoined: alreadyJoined,
            assignedStoreIds: Array(assignedStoreIds).sorted()
        )
    }

    func leaveStore(storeId: String) async throws {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        let membershipRecordID = CloudKitService.membershipRecordID(storeId: storeId, employeeId: currentUserId)
        guard let membership = try await service.fetchRecord(with: membershipRecordID) else {
            return
        }

        membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.removed as CKRecordValue
        membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue

        let userRecordID = CloudKitService.userRecordID(userId: currentUserId)
        let userRecord = try await service.fetchRecord(with: userRecordID)
        if let userRecord {
            var assignedStoreIds = Set(userRecord.stringArray(CKSchema.UserField.assignedStoreIds))
            assignedStoreIds.remove(storeId)
            userRecord[CKSchema.UserField.assignedStoreIds] = Array(assignedStoreIds).sorted() as CKRecordValue
            userRecord[CKSchema.UserField.updatedAt] = Date() as CKRecordValue
            _ = try await service.modify(recordsToSave: [membership, userRecord])
        } else {
            _ = try await service.save(record: membership)
        }
    }

    private func recomputeAssignedStores(for employeeId: String) async throws {
        let activeMemberships = try await service.queryRecords(
            recordType: CKSchema.RecordType.storeMember,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.employeeUserId, employeeId),
                NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.status, CKSchema.MemberStatus.active)
            ])
        )

        var activeStoreIds: [String] = []
        for membership in activeMemberships {
            guard let storeId = membership.string(CKSchema.StoreMemberField.storeId) else { continue }
            guard let storeRecord = try await service.fetchRecord(with: CloudKitService.storeRecordID(storeId: storeId)),
                  storeRecord.bool(CKSchema.StoreField.isActive, default: true) else {
                continue
            }
            activeStoreIds.append(storeId)
        }

        guard let userRecord = try await service.fetchRecord(with: CloudKitService.userRecordID(userId: employeeId)) else {
            return
        }

        userRecord[CKSchema.UserField.assignedStoreIds] = Array(Set(activeStoreIds)).sorted() as CKRecordValue
        userRecord[CKSchema.UserField.updatedAt] = Date() as CKRecordValue
        _ = try await service.save(record: userRecord)
    }

    private func validateStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            throw CloudKitClientError.invalidData("Store name is required.")
        }

        guard !trimmedAddress.isEmpty else {
            throw CloudKitClientError.invalidData("Store address is required.")
        }

        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw CloudKitClientError.invalidData("Store coordinates are invalid.")
        }

        guard radiusMeters > 0 else {
            throw CloudKitClientError.invalidData("Store radius must be greater than zero.")
        }
    }

    private func normalizeJoinCode(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private static func generateJoinCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}
