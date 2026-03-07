import CloudKit
import CryptoKit
import Foundation

@MainActor
protocol UserRepositoryProtocol {
    func fetchUser(id: String) async throws -> UserProfile?
    func upsertUser(_ user: UserProfile) async throws
}

@MainActor
protocol EmployeeManagementRepositoryProtocol {
    func fetchManagerStores(managerId: String) async throws -> [Store]
    func fetchEmployeesForManagerStores(managerStores: [Store]) async throws -> [EmployeeSummary]
    func fetchEmployeesForManager(managerId: String) async throws -> [EmployeeSummary]
    func removeEmployeeFromStore(storeId: String, employeeId: String) async throws
    func removeEmployeeFromAllManagerStores(employeeId: String, managerId: String) async throws
    func setEmployeeStoresForManager(employeeId: String, storeIds: [String]) async throws
    func setEmployeeActive(employeeId: String, isActive: Bool) async throws
}

enum CloudKitClientError: LocalizedError {
    case iCloudUnavailable
    case signedOut
    case missingRecord(String)
    case invalidData(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud is unavailable. Sign in to iCloud in Settings to use StorePass."
        case .signedOut:
            return "You are signed out. Please sign in with Apple."
        case .missingRecord(let message):
            return message
        case .invalidData(let message):
            return message
        case .unauthorized:
            return "CloudKit denied this action. In CloudKit Dashboard, set _icloud role to Create/Read/Write for User (or Users), Store, StoreMember, CheckInSession; Save and Deploy Schema Changes."
        }
    }
}

enum CKSchema {
    enum RecordType {
        static let user = "User"
        static let legacyUsers = "Users"
        static let store = "Store"
        static let storeMember = "StoreMember"
        static let checkInSession = "CheckInSession"
    }

    enum UserField {
        static let userId = "userId"
        static let role = "role"
        static let name = "name"
        static let email = "email"
        static let isActive = "isActive"
        static let provider = "provider"
        static let assignedStoreIds = "assignedStoreIds"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
        static let deletedAt = "deletedAt"
    }

    enum StoreField {
        static let storeId = "storeId"
        static let managerUserRef = "managerUserRef"
        static let managerUserId = "managerUserId"
        static let name = "name"
        static let address = "address"
        static let latitude = "locationLat"
        static let longitude = "locationLng"
        static let radiusMeters = "radiusMeters"
        static let joinCodeHash = "joinCodeHash"
        static let joinCode = "joinCode"
        static let joinCodeLast4 = "joinCodeLast4"
        static let isActive = "isActive"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
        static let deletedAt = "deletedAt"
    }

    enum StoreMemberField {
        static let memberId = "memberId"
        static let storeRef = "storeRef"
        static let storeId = "storeId"
        static let employeeUserRef = "employeeUserRef"
        static let employeeUserId = "employeeUserId"
        static let employeeName = "employeeName"
        static let employeeEmail = "employeeEmail"
        static let status = "status"
        static let joinedAt = "joinedAt"
        static let updatedAt = "updatedAt"
    }

    enum MemberStatus {
        static let active = "active"
        static let removed = "removed"
    }
}

extension CKRecord {
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String, default fallback: Bool = false) -> Bool { (self[key] as? NSNumber)?.boolValue ?? (self[key] as? Bool) ?? fallback }
    func int(_ key: String, default fallback: Int = 0) -> Int { (self[key] as? NSNumber)?.intValue ?? fallback }
    func date(_ key: String) -> Date? { self[key] as? Date }
    func stringArray(_ key: String) -> [String] { self[key] as? [String] ?? [] }
}

func decodeUserProfile(record: CKRecord) -> UserProfile? {
    guard let userId = record.string(CKSchema.UserField.userId),
          let roleRaw = record.string(CKSchema.UserField.role),
          let role = UserRole(rawValue: roleRaw) else {
        return nil
    }

    return UserProfile(
        id: userId,
        name: record.string(CKSchema.UserField.name) ?? "StorePass User",
        email: record.string(CKSchema.UserField.email),
        role: role,
        createdAt: record.date(CKSchema.UserField.createdAt) ?? Date(),
        lastLoginAt: record.date(CKSchema.UserField.updatedAt) ?? Date(),
        provider: record.string(CKSchema.UserField.provider) ?? "apple",
        assignedStoreIds: record.stringArray(CKSchema.UserField.assignedStoreIds),
        isActive: record.bool(CKSchema.UserField.isActive, default: true)
    )
}

func decodeStore(record: CKRecord) -> Store? {
    guard let storeId = record.string(CKSchema.StoreField.storeId),
          let name = record.string(CKSchema.StoreField.name),
          let managerId = record.string(CKSchema.StoreField.managerUserId) else {
        return nil
    }

    return Store(
        id: storeId,
        name: name,
        address: record.string(CKSchema.StoreField.address) ?? "",
        latitude: (record[CKSchema.StoreField.latitude] as? NSNumber)?.doubleValue ?? 0,
        longitude: (record[CKSchema.StoreField.longitude] as? NSNumber)?.doubleValue ?? 0,
        radiusMeters: record.int(CKSchema.StoreField.radiusMeters, default: 150),
        isActive: record.bool(CKSchema.StoreField.isActive, default: true),
        managerId: managerId,
        createdAt: record.date(CKSchema.StoreField.createdAt),
        updatedAt: record.date(CKSchema.StoreField.updatedAt),
        joinCode: record.string(CKSchema.StoreField.joinCode),
        joinCodeCiphertext: record.string(CKSchema.StoreField.joinCode),
        joinCodeLast4: record.string(CKSchema.StoreField.joinCodeLast4)
    )
}

@MainActor
final class CloudKitService {
    let container: CKContainer
    let publicDB: CKDatabase
    let privateDB: CKDatabase
    private weak var authService: AuthService?

    init(container: CKContainer = .default(), authService: AuthService) {
        self.container = container
        self.publicDB = container.publicCloudDatabase
        self.privateDB = container.privateCloudDatabase
        self.authService = authService
    }

    var currentUserId: String? {
        authService?.currentIdentity?.userId
    }

    var currentRole: UserRole? {
        authService?.currentUser?.role
    }

    func requireCurrentUserId() throws -> String {
        guard let currentUserId else {
            throw CloudKitClientError.signedOut
        }
        return currentUserId
    }

    func ensureCloudKitAvailable() async throws {
        let status = try await accountStatus()
        guard status == .available else {
            throw CloudKitClientError.iCloudUnavailable
        }
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    func fetchRecord(with id: CKRecord.ID, in database: CKDatabase? = nil) async throws -> CKRecord? {
        let db = database ?? publicDB
        return try await withCheckedThrowingContinuation { continuation in
            db.fetch(withRecordID: id) { record, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    continuation.resume(throwing: self.mapCloudKitError(error))
                    return
                }
                continuation.resume(returning: record)
            }
        }
    }

    func save(record: CKRecord, in database: CKDatabase? = nil) async throws -> CKRecord {
        let db = database ?? publicDB
        return try await withCheckedThrowingContinuation { continuation in
            db.save(record) { saved, error in
                if let error {
                    continuation.resume(throwing: self.mapCloudKitError(error))
                    return
                }
                guard let saved else {
                    continuation.resume(throwing: CloudKitClientError.invalidData("CloudKit did not return a saved record."))
                    return
                }
                continuation.resume(returning: saved)
            }
        }
    }

    func deleteRecord(with id: CKRecord.ID, in database: CKDatabase? = nil) async throws {
        let db = database ?? publicDB
        _ = try await withCheckedThrowingContinuation { continuation in
            db.delete(withRecordID: id) { _, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    continuation.resume(returning: ())
                    return
                }
                if let error {
                    continuation.resume(throwing: self.mapCloudKitError(error))
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    func modify(
        recordsToSave: [CKRecord],
        recordIDsToDelete: [CKRecord.ID] = [],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .changedKeys,
        atomic: Bool = false,
        in database: CKDatabase? = nil
    ) async throws -> ([CKRecord], [CKRecord.ID]) {
        let db = database ?? publicDB
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
            operation.savePolicy = savePolicy
            operation.isAtomic = atomic
            operation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, error in
                if let error {
                    continuation.resume(throwing: self.mapCloudKitError(error))
                    return
                }
                continuation.resume(returning: (savedRecords ?? [], deletedRecordIDs ?? []))
            }
            db.add(operation)
        }
    }

    func queryRecords(
        recordType: String,
        predicate: NSPredicate,
        sortDescriptors: [NSSortDescriptor] = [],
        resultsLimit: Int = CKQueryOperation.maximumResults,
        in database: CKDatabase? = nil
    ) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors
        let db = database ?? publicDB
        return try await queryRecords(query: query, resultsLimit: resultsLimit, in: db)
    }

    func queryRecords(
        query: CKQuery,
        resultsLimit: Int = CKQueryOperation.maximumResults,
        in database: CKDatabase
    ) async throws -> [CKRecord] {
        var allRecords: [CKRecord] = []
        var nextCursor: CKQueryOperation.Cursor?

        repeat {
            let (records, cursor) = try await fetchBatch(query: query, cursor: nextCursor, resultsLimit: resultsLimit, in: database)
            allRecords.append(contentsOf: records)
            nextCursor = cursor
        } while nextCursor != nil

        return allRecords
    }

    private func fetchBatch(
        query: CKQuery,
        cursor: CKQueryOperation.Cursor?,
        resultsLimit: Int,
        in database: CKDatabase
    ) async throws -> ([CKRecord], CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            let operation: CKQueryOperation
            if let cursor {
                operation = CKQueryOperation(cursor: cursor)
            } else {
                operation = CKQueryOperation(query: query)
            }

            operation.resultsLimit = resultsLimit

            var fetchedRecords: [CKRecord] = []
            operation.recordFetchedBlock = { record in
                fetchedRecords.append(record)
            }

            operation.queryCompletionBlock = { nextCursor, error in
                if let error {
                    continuation.resume(throwing: self.mapCloudKitError(error))
                    return
                }
                continuation.resume(returning: (fetchedRecords, nextCursor))
            }

            database.add(operation)
        }
    }

    func saveSubscription(_ subscription: CKSubscription) async throws {
        _ = try await withCheckedThrowingContinuation { continuation in
            publicDB.save(subscription) { saved, error in
                if let ckError = error as? CKError, ckError.code == .serverRejectedRequest {
                    // Existing subscription IDs can return server-rejected on duplicate create; treat as success.
                    continuation.resume(returning: saved as Any)
                    return
                }
                if let error {
                    continuation.resume(throwing: self.mapCloudKitError(error))
                    return
                }
                continuation.resume(returning: saved as Any)
            }
        }
    }

    func bootstrapSubscriptions(for userId: String, role: UserRole) async {
        do {
            let membershipPredicate = NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.employeeUserId, userId)
            let membershipSubscription = CKQuerySubscription(
                recordType: CKSchema.RecordType.storeMember,
                predicate: membershipPredicate,
                subscriptionID: "membership_\(CloudKitService.stableHash(userId))",
                options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
            )
            let memberInfo = CKSubscription.NotificationInfo()
            memberInfo.shouldSendContentAvailable = true
            membershipSubscription.notificationInfo = memberInfo
            try await saveSubscription(membershipSubscription)

            if role == .manager {
                let managerPredicate = NSPredicate(format: "%K == %@", CKSchema.StoreField.managerUserId, userId)
                let managerStoreSubscription = CKQuerySubscription(
                    recordType: CKSchema.RecordType.store,
                    predicate: managerPredicate,
                    subscriptionID: "manager_store_\(CloudKitService.stableHash(userId))",
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
                )
                let managerInfo = CKSubscription.NotificationInfo()
                managerInfo.shouldSendContentAvailable = true
                managerStoreSubscription.notificationInfo = managerInfo
                try await saveSubscription(managerStoreSubscription)
            }
        } catch {
            AppLog.warning("CloudKit subscription setup skipped: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    func mapCloudKitError(_ error: Error) -> Error {
        guard let ckError = error as? CKError else { return error }

        switch ckError.code {
        case .notAuthenticated:
            return CloudKitClientError.iCloudUnavailable
        case .permissionFailure:
            return CloudKitClientError.unauthorized
        case .quotaExceeded:
            return NSError(domain: "StorePass", code: 9201, userInfo: [NSLocalizedDescriptionKey: "Cloud storage quota is exceeded. Please free up iCloud space and retry."])
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return NSError(domain: "StorePass", code: 9202, userInfo: [NSLocalizedDescriptionKey: "CloudKit is temporarily unavailable. Please retry."])
        default:
            return ckError
        }
    }

    static func userRecordID(userId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "user_\(stableHash(userId))")
    }

    static func storeRecordID(storeId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "store_\(stableHash(storeId))")
    }

    static func membershipRecordID(storeId: String, employeeId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "member_\(stableHash("\(storeId)|\(employeeId)"))")
    }

    static func checkInRecordID(checkInId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "checkin_\(stableHash(checkInId))")
    }

    static func stableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class CloudKitUserRepository: UserRepositoryProtocol {
    private let service: CloudKitService

    init(service: CloudKitService) {
        self.service = service
    }

    func fetchUser(id: String) async throws -> UserProfile? {
        try await service.ensureCloudKitAvailable()
        let recordID = CloudKitService.userRecordID(userId: id)
        guard let record = try await service.fetchRecord(with: recordID) else {
            return nil
        }

        return decodeUserProfile(record: record)
    }

    func upsertUser(_ user: UserProfile) async throws {
        try await service.ensureCloudKitAvailable()

        let recordID = CloudKitService.userRecordID(userId: user.id)
        let record = try await service.fetchRecord(with: recordID) ?? CKRecord(recordType: CKSchema.RecordType.user, recordID: recordID)

        record[CKSchema.UserField.userId] = user.id as CKRecordValue
        record[CKSchema.UserField.role] = user.role.rawValue as CKRecordValue
        record[CKSchema.UserField.name] = user.name as CKRecordValue
        if let email = user.email, !email.isEmpty {
            record[CKSchema.UserField.email] = email as CKRecordValue
        }
        record[CKSchema.UserField.isActive] = NSNumber(value: user.isActive)
        record[CKSchema.UserField.provider] = user.provider as CKRecordValue
        record[CKSchema.UserField.assignedStoreIds] = user.assignedStoreIds as CKRecordValue
        record[CKSchema.UserField.createdAt] = (record.date(CKSchema.UserField.createdAt) ?? user.createdAt) as CKRecordValue
        record[CKSchema.UserField.updatedAt] = Date() as CKRecordValue

        _ = try await service.save(record: record)
    }
}

final class CloudKitEmployeeManagementRepository: EmployeeManagementRepositoryProtocol {
    private let service: CloudKitService

    init(service: CloudKitService) {
        self.service = service
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

    func fetchEmployeesForManagerStores(managerStores: [Store]) async throws -> [EmployeeSummary] {
        try await service.ensureCloudKitAvailable()
        guard !managerStores.isEmpty else { return [] }

        let storesById = Dictionary(uniqueKeysWithValues: managerStores.map { ($0.id, $0) })
        var storeIdsByEmployee: [String: Set<String>] = [:]

        for store in managerStores {
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.storeId, store.id),
                NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.status, CKSchema.MemberStatus.active)
            ])

            let membershipRecords = try await service.queryRecords(recordType: CKSchema.RecordType.storeMember, predicate: predicate)
            for record in membershipRecords {
                guard let employeeId = record.string(CKSchema.StoreMemberField.employeeUserId) else { continue }
                storeIdsByEmployee[employeeId, default: []].insert(store.id)
            }
        }

        var summaries: [EmployeeSummary] = []
        for (employeeId, memberships) in storeIdsByEmployee {
            guard let userRecord = try await service.fetchRecord(with: CloudKitService.userRecordID(userId: employeeId)),
                  let user = decodeUserProfile(record: userRecord),
                  user.role == .employee else {
                continue
            }

            let sortedIds = memberships.sorted()
            let storeNames = sortedIds.compactMap { storesById[$0]?.name }
            summaries.append(
                EmployeeSummary(
                    id: employeeId,
                    name: user.name,
                    email: user.email,
                    storeIds: sortedIds,
                    storeNames: storeNames,
                    userIsActive: user.isActive,
                    hasInactiveMembership: false
                )
            )
        }

        return summaries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchEmployeesForManager(managerId: String) async throws -> [EmployeeSummary] {
        let stores = try await fetchManagerStores(managerId: managerId)
        return try await fetchEmployeesForManagerStores(managerStores: stores)
    }

    func removeEmployeeFromStore(storeId: String, employeeId: String) async throws {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        try await assertStoreManagedByCurrentUser(storeId: storeId, expectedManagerId: currentUserId)

        let membershipId = CloudKitService.membershipRecordID(storeId: storeId, employeeId: employeeId)
        guard let membership = try await service.fetchRecord(with: membershipId) else {
            return
        }

        membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.removed as CKRecordValue
        membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue
        _ = try await service.save(record: membership)

        try await recomputeAssignedStores(for: employeeId)
    }

    func removeEmployeeFromAllManagerStores(employeeId: String, managerId: String) async throws {
        let managerStores = try await fetchManagerStores(managerId: managerId)
        for store in managerStores {
            try await removeEmployeeFromStore(storeId: store.id, employeeId: employeeId)
        }
    }

    func setEmployeeStoresForManager(employeeId: String, storeIds: [String]) async throws {
        try await service.ensureCloudKitAvailable()
        let managerId = try service.requireCurrentUserId()

        let managerStores = try await fetchManagerStores(managerId: managerId)
        let managerStoreIds = Set(managerStores.map(\.id))
        let targetStoreIds = Set(storeIds)

        var recordsToSave: [CKRecord] = []

        for managedStoreId in managerStoreIds {
            let membershipRecordID = CloudKitService.membershipRecordID(storeId: managedStoreId, employeeId: employeeId)
            let membership = try await service.fetchRecord(with: membershipRecordID) ?? CKRecord(recordType: CKSchema.RecordType.storeMember, recordID: membershipRecordID)

            membership[CKSchema.StoreMemberField.memberId] = membershipRecordID.recordName as CKRecordValue
            membership[CKSchema.StoreMemberField.storeId] = managedStoreId as CKRecordValue
            membership[CKSchema.StoreMemberField.employeeUserId] = employeeId as CKRecordValue

            if let storeRecord = try await service.fetchRecord(with: CloudKitService.storeRecordID(storeId: managedStoreId)) {
                membership[CKSchema.StoreMemberField.storeRef] = CKRecord.Reference(recordID: storeRecord.recordID, action: .none)
            }
            if let employeeRecord = try await service.fetchRecord(with: CloudKitService.userRecordID(userId: employeeId)) {
                membership[CKSchema.StoreMemberField.employeeUserRef] = CKRecord.Reference(recordID: employeeRecord.recordID, action: .none)
                membership[CKSchema.StoreMemberField.employeeName] = (employeeRecord.string(CKSchema.UserField.name) ?? "Employee") as CKRecordValue
                if let email = employeeRecord.string(CKSchema.UserField.email), !email.isEmpty {
                    membership[CKSchema.StoreMemberField.employeeEmail] = email as CKRecordValue
                }
            }

            let shouldBeActive = targetStoreIds.contains(managedStoreId)
            membership[CKSchema.StoreMemberField.status] = (shouldBeActive ? CKSchema.MemberStatus.active : CKSchema.MemberStatus.removed) as CKRecordValue
            if membership.date(CKSchema.StoreMemberField.joinedAt) == nil {
                membership[CKSchema.StoreMemberField.joinedAt] = Date() as CKRecordValue
            }
            membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue
            recordsToSave.append(membership)
        }

        _ = try await service.modify(recordsToSave: recordsToSave)
        try await recomputeAssignedStores(for: employeeId)
    }

    func setEmployeeActive(employeeId: String, isActive: Bool) async throws {
        try await service.ensureCloudKitAvailable()

        let userRecordID = CloudKitService.userRecordID(userId: employeeId)
        guard let userRecord = try await service.fetchRecord(with: userRecordID) else {
            throw CloudKitClientError.missingRecord("Employee account was not found.")
        }

        userRecord[CKSchema.UserField.isActive] = NSNumber(value: isActive)
        userRecord[CKSchema.UserField.updatedAt] = Date() as CKRecordValue
        if !isActive {
            userRecord[CKSchema.UserField.assignedStoreIds] = [] as CKRecordValue
        }

        var recordsToSave: [CKRecord] = [userRecord]

        if !isActive {
            let membershipRecords = try await service.queryRecords(
                recordType: CKSchema.RecordType.storeMember,
                predicate: NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.employeeUserId, employeeId)
            )

            for membership in membershipRecords {
                membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.removed as CKRecordValue
                membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue
                recordsToSave.append(membership)
            }
        }

        _ = try await service.modify(recordsToSave: recordsToSave)
        if isActive {
            try await recomputeAssignedStores(for: employeeId)
        }
    }

    private func assertStoreManagedByCurrentUser(storeId: String, expectedManagerId: String) async throws {
        guard let storeRecord = try await service.fetchRecord(with: CloudKitService.storeRecordID(storeId: storeId)) else {
            throw CloudKitClientError.missingRecord("Store could not be found.")
        }

        let managerId = storeRecord.string(CKSchema.StoreField.managerUserId)
        guard managerId == expectedManagerId else {
            throw CloudKitClientError.unauthorized
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

        let userRecordID = CloudKitService.userRecordID(userId: employeeId)
        guard let userRecord = try await service.fetchRecord(with: userRecordID) else {
            return
        }

        userRecord[CKSchema.UserField.assignedStoreIds] = Array(Set(activeStoreIds)).sorted() as CKRecordValue
        userRecord[CKSchema.UserField.updatedAt] = Date() as CKRecordValue
        _ = try await service.save(record: userRecord)
    }
}
