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
    func updateEmployeeProfile(employeeId: String, name: String, hourlyRateCents: Int?, expectedStartMinutesFromMidnight: Int?) async throws
    func removeEmployeeFromStore(storeId: String, employeeId: String) async throws
    func removeEmployeeFromAllManagerStores(employeeId: String, managerId: String) async throws
    func setEmployeeStoresForManager(employeeId: String, storeIds: [String]) async throws
    func setEmployeeActive(employeeId: String, isActive: Bool) async throws
    func fetchStoreActivityFeed(managerId: String, storeId: String, limit: Int) async throws -> [StoreActivityEvent]
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
        static let broadcastMessage = "BroadcastMessage"
    }

    enum UserField {
        static let userId = "userId"
        static let role = "role"
        static let name = "name"
        static let email = "email"
        static let isActive = "isActive"
        static let provider = "provider"
        static let assignedStoreIds = "assignedStoreIds"
        static let hourlyRateCents = "hourlyRateCents"
        static let expectedStartMinutesFromMidnight = "expectedStartMinutesFromMidnight"
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
        static let timeZoneIdentifier = "timeZoneIdentifier"
        static let qrCheckInEnabled = "qrCheckInEnabled"
        static let qrCodeToken = "qrCodeToken"
        static let longShiftWarningHours = "longShiftWarningHours"
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

    enum BroadcastField {
        static let messageId = "messageId"
        static let storeId = "storeId"
        static let storeRef = "storeRef"
        static let storeName = "storeName"
        static let managerUserId = "managerUserId"
        static let managerName = "managerName"
        static let message = "message"
        static let createdAt = "createdAt"
    }
}

extension CKRecord {
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String, default fallback: Bool = false) -> Bool { (self[key] as? NSNumber)?.boolValue ?? (self[key] as? Bool) ?? fallback }
    func int(_ key: String, default fallback: Int = 0) -> Int { (self[key] as? NSNumber)?.intValue ?? fallback }
    func intOptional(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
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
        isActive: record.bool(CKSchema.UserField.isActive, default: true),
        hourlyRateCents: record.intOptional(CKSchema.UserField.hourlyRateCents),
        expectedStartMinutesFromMidnight: record.intOptional(CKSchema.UserField.expectedStartMinutesFromMidnight)
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
        joinCodeLast4: record.string(CKSchema.StoreField.joinCodeLast4),
        timeZoneIdentifier: record.string(CKSchema.StoreField.timeZoneIdentifier) ?? TimeZone.current.identifier,
        qrCheckInEnabled: record.bool(CKSchema.StoreField.qrCheckInEnabled, default: false),
        qrCodeToken: record.string(CKSchema.StoreField.qrCodeToken),
        longShiftWarningHours: max(record.int(CKSchema.StoreField.longShiftWarningHours, default: 10), 1)
    )
}

struct CloudKitMigrationPolicy {
    func shouldSuppress(
        _ error: Error,
        tolerateLookupErrors: Bool,
        suppressPermissionErrors: Bool
    ) -> Bool {
        if suppressPermissionErrors,
           let clientError = error as? CloudKitClientError,
           case .unauthorized = clientError {
            AppLog.warning("ProfileStore shouldSuppress=true for CloudKitClientError.unauthorized")
            return true
        }

        if suppressPermissionErrors,
           let ckError = error as? CKError,
           ckError.code == .permissionFailure {
            AppLog.warning("ProfileStore shouldSuppress=true for CKError.permissionFailure")
            return true
        }

        if tolerateLookupErrors && isSchemaMismatch(error) {
            AppLog.warning("ProfileStore shouldSuppress=true for schema mismatch")
            return true
        }

        if tolerateLookupErrors,
           let ckError = error as? CKError,
           ckError.code == .unknownItem {
            AppLog.warning("ProfileStore shouldSuppress=true for CKError.unknownItem")
            return true
        }

        return false
    }

    func shouldFallbackToLegacyAfterPrimarySaveFailure(_ error: Error) -> Bool {
        if isSchemaMismatch(error) {
            AppLog.warning("ProfileStore shouldFallbackToLegacyAfterPrimarySaveFailure=true due to schema mismatch")
            return true
        }

        if let clientError = error as? CloudKitClientError,
           case .unauthorized = clientError {
            AppLog.warning("ProfileStore shouldFallbackToLegacyAfterPrimarySaveFailure=true due to unauthorized")
            return true
        }

        if let ckError = error as? CKError,
           ckError.code == .permissionFailure {
            AppLog.warning("ProfileStore shouldFallbackToLegacyAfterPrimarySaveFailure=true due to CKError.permissionFailure")
            return true
        }

        return false
    }

    func isSchemaMismatch(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .invalidArguments, .serverRejectedRequest, .unknownItem:
                return true
            case .partialFailure:
                if let partial = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
                   !partial.isEmpty {
                    return partial.values.allSatisfy { isSchemaMismatch($0) }
                }
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
}

private enum CloudKitIdentityMismatchState {
    private static let lock = NSLock()
    private static var detected = false
    private static var cachedMessage: String?

    static func markDetected(message: String) {
        lock.lock()
        defer { lock.unlock() }
        detected = true
        cachedMessage = message
    }

    static func isDetected() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return detected
    }

    static func message() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedMessage
    }
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

    nonisolated var isCloudKitIdentityMismatchDetected: Bool {
        CloudKitIdentityMismatchState.isDetected()
    }

    nonisolated var cloudKitIdentityMismatchMessage: String? {
        CloudKitIdentityMismatchState.message()
    }

    func requireCurrentUserId() throws -> String {
        guard let currentUserId else {
            throw CloudKitClientError.signedOut
        }
        return currentUserId
    }

    func ensureCloudKitAvailable() async throws {
        let status = try await accountStatus()
        AppLog.info("CloudKit account status=\(accountStatusName(status))")
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
        if let mismatchError = cloudKitIdentityMismatchErrorIfAny() {
            throw mismatchError
        }
        let db = database ?? publicDB
        let scope = databaseScopeName(db)
        AppLog.info("CloudKit fetchRecord started scope=\(scope) recordID=\(id.recordName)")
        return try await withCheckedThrowingContinuation { continuation in
            db.fetch(withRecordID: id) { record, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    AppLog.info("CloudKit fetchRecord missing item scope=\(scope) recordID=\(id.recordName)")
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    continuation.resume(
                        throwing: self.mapCloudKitError(
                            error,
                            context: "fetchRecord scope=\(scope) recordID=\(id.recordName)"
                        )
                    )
                    return
                }
                AppLog.info("CloudKit fetchRecord success scope=\(scope) recordID=\(id.recordName)")
                continuation.resume(returning: record)
            }
        }
    }

    func save(record: CKRecord, in database: CKDatabase? = nil) async throws -> CKRecord {
        if let mismatchError = cloudKitIdentityMismatchErrorIfAny() {
            throw mismatchError
        }
        let db = database ?? publicDB
        let scope = databaseScopeName(db)
        AppLog.info(
            "CloudKit save started scope=\(scope) type=\(record.recordType) recordID=\(record.recordID.recordName)"
        )
        return try await withCheckedThrowingContinuation { continuation in
            db.save(record) { saved, error in
                if let error {
                    continuation.resume(
                        throwing: self.mapCloudKitError(
                            error,
                            context: "save scope=\(scope) type=\(record.recordType) recordID=\(record.recordID.recordName)"
                        )
                    )
                    return
                }
                guard let saved else {
                    continuation.resume(throwing: CloudKitClientError.invalidData("CloudKit did not return a saved record."))
                    return
                }
                AppLog.info(
                    "CloudKit save success scope=\(scope) type=\(saved.recordType) recordID=\(saved.recordID.recordName)"
                )
                continuation.resume(returning: saved)
            }
        }
    }

    func deleteRecord(with id: CKRecord.ID, in database: CKDatabase? = nil) async throws {
        if let mismatchError = cloudKitIdentityMismatchErrorIfAny() {
            throw mismatchError
        }
        let db = database ?? publicDB
        let scope = databaseScopeName(db)
        AppLog.info("CloudKit delete started scope=\(scope) recordID=\(id.recordName)")
        _ = try await withCheckedThrowingContinuation { continuation in
            db.delete(withRecordID: id) { _, error in
                if let ckError = error as? CKError, ckError.code == .unknownItem {
                    AppLog.info("CloudKit delete ignored unknown item scope=\(scope) recordID=\(id.recordName)")
                    continuation.resume(returning: ())
                    return
                }
                if let error {
                    continuation.resume(
                        throwing: self.mapCloudKitError(
                            error,
                            context: "deleteRecord scope=\(scope) recordID=\(id.recordName)"
                        )
                    )
                    return
                }
                AppLog.info("CloudKit delete success scope=\(scope) recordID=\(id.recordName)")
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
        if let mismatchError = cloudKitIdentityMismatchErrorIfAny() {
            throw mismatchError
        }
        let db = database ?? publicDB
        let scope = databaseScopeName(db)
        AppLog.info(
            "CloudKit modify started scope=\(scope) saves=\(recordsToSave.count) deletes=\(recordIDsToDelete.count) atomic=\(atomic)"
        )
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
            operation.savePolicy = savePolicy
            operation.isAtomic = atomic
            operation.modifyRecordsCompletionBlock = { savedRecords, deletedRecordIDs, error in
                if let error {
                    continuation.resume(
                        throwing: self.mapCloudKitError(
                            error,
                            context: "modify scope=\(scope) saves=\(recordsToSave.count) deletes=\(recordIDsToDelete.count) atomic=\(atomic)"
                        )
                    )
                    return
                }
                AppLog.info(
                    "CloudKit modify success scope=\(scope) saved=\(savedRecords?.count ?? 0) deleted=\(deletedRecordIDs?.count ?? 0)"
                )
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
        if let mismatchError = cloudKitIdentityMismatchErrorIfAny() {
            throw mismatchError
        }
        let query = CKQuery(recordType: recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors
        let db = database ?? publicDB
        AppLog.info(
            "CloudKit query started scope=\(databaseScopeName(db)) type=\(recordType) limit=\(resultsLimit) predicate=\(AppLog.sanitize(predicate.predicateFormat))"
        )
        return try await queryRecords(query: query, resultsLimit: resultsLimit, in: db)
    }

    func queryRecords(
        query: CKQuery,
        resultsLimit: Int = CKQueryOperation.maximumResults,
        in database: CKDatabase
    ) async throws -> [CKRecord] {
        if let mismatchError = cloudKitIdentityMismatchErrorIfAny() {
            throw mismatchError
        }
        var allRecords: [CKRecord] = []
        var nextCursor: CKQueryOperation.Cursor?
        AppLog.info(
            "CloudKit queryRecords paging started scope=\(databaseScopeName(database)) type=\(query.recordType)"
        )

        repeat {
            let (records, cursor) = try await fetchBatch(query: query, cursor: nextCursor, resultsLimit: resultsLimit, in: database)
            allRecords.append(contentsOf: records)
            nextCursor = cursor
        } while nextCursor != nil

        AppLog.info(
            "CloudKit queryRecords paging finished scope=\(databaseScopeName(database)) type=\(query.recordType) total=\(allRecords.count)"
        )
        return allRecords
    }

    private func fetchBatch(
        query: CKQuery,
        cursor: CKQueryOperation.Cursor?,
        resultsLimit: Int,
        in database: CKDatabase
    ) async throws -> ([CKRecord], CKQueryOperation.Cursor?) {
        let scope = databaseScopeName(database)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([CKRecord], CKQueryOperation.Cursor?), Error>) in
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
                    continuation.resume(
                        throwing: self.mapCloudKitError(
                            error,
                            context: "queryBatch scope=\(scope) type=\(query.recordType) limit=\(resultsLimit)"
                        )
                    )
                    return
                }
                AppLog.info(
                    "CloudKit query batch success scope=\(scope) type=\(query.recordType) fetched=\(fetchedRecords.count) hasMore=\(nextCursor != nil)"
                )
                continuation.resume(returning: (fetchedRecords, nextCursor))
            }

            database.add(operation)
        }
    }

    func saveSubscription(_ subscription: CKSubscription) async throws {
        if let mismatchError = cloudKitIdentityMismatchErrorIfAny() {
            throw mismatchError
        }
        AppLog.info("CloudKit saveSubscription started id=\(subscription.subscriptionID)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            publicDB.save(subscription) { _, error in
                if let ckError = error as? CKError, ckError.code == .serverRejectedRequest {
                    // Existing subscription IDs can return server-rejected on duplicate create; treat as success.
                    AppLog.warning("CloudKit saveSubscription serverRejectedRequest treated as success id=\(subscription.subscriptionID)")
                    continuation.resume(returning: ())
                    return
                }
                if let error {
                    continuation.resume(
                        throwing: self.mapCloudKitError(
                            error,
                            context: "saveSubscription id=\(subscription.subscriptionID)"
                        )
                    )
                    return
                }
                AppLog.info("CloudKit saveSubscription success id=\(subscription.subscriptionID)")
                continuation.resume(returning: ())
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

    nonisolated func mapCloudKitError(_ error: Error) -> Error {
        mapCloudKitError(error, context: nil)
    }

    nonisolated func mapCloudKitError(_ error: Error, context: String?) -> Error {
        guard let ckError = error as? CKError else { return error }
        let normalizedError = normalizeCloudKitError(ckError)
        let normalizedDescription = normalizedError.localizedDescription.lowercased()

        let nsError = normalizedError as NSError
        var message = "CloudKit error mapped"
        if let context {
            message += " [\(context)]"
        }
        message += " code=\(normalizedError.code.rawValue) (\(normalizedError.code))"
        message += " domain=\(nsError.domain)"
        message += " message=\(AppLog.sanitize(normalizedError.localizedDescription))"
        if let retryAfter = normalizedError.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
            message += " retryAfter=\(retryAfter)"
        }
        if normalizedError.code == .partialFailure,
           let partial = normalizedError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            let partialCodes = partial.values.compactMap { ($0 as? CKError)?.code.rawValue }
            message += " partialCount=\(partial.count)"
            if !partialCodes.isEmpty {
                message += " partialCodes=\(partialCodes)"
            }
        }
        AppLog.warning(message)

        if CloudKitMigrationPolicy().isSchemaMismatch(normalizedError) {
            return CloudKitClientError.invalidData(
                "CloudKit schema mismatch detected. Deploy schema updates for User, Store, StoreMember, and CheckInSession before retrying."
            )
        }

        if normalizedError.code == .permissionFailure,
           normalizedDescription.contains("invalid bundle id") &&
           normalizedDescription.contains("container") {
            let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
            let expectedContainer = "iCloud.\(bundleID)"
            let signing = SigningDiagnostics.snapshot()
            let signedAppIdentifier = signing.applicationIdentifier ?? "unknown"
            let entitledContainers = signing.iCloudContainerIdentifiers.isEmpty
                ? "none"
                : signing.iCloudContainerIdentifiers.joined(separator: ",")
            let mismatchMessage =
                "CloudKit rejected this app identity (Invalid bundle ID for container). " +
                "bundleID='\(bundleID)' expectedContainer='\(expectedContainer)' " +
                "signedAppIdentifier='\(signedAppIdentifier)' entitledContainers='\(entitledContainers)'. " +
                "In Apple Developer and Xcode, link this bundle ID to that container, regenerate profiles, rebuild, and retry."
            CloudKitIdentityMismatchState.markDetected(message: mismatchMessage)
            return CloudKitClientError.invalidData(mismatchMessage)
        }

        switch normalizedError.code {
        case .notAuthenticated:
            return CloudKitClientError.iCloudUnavailable
        case .permissionFailure:
            return CloudKitClientError.unauthorized
        case .quotaExceeded:
            return NSError(domain: "StorePass", code: 9201, userInfo: [NSLocalizedDescriptionKey: "Cloud storage quota is exceeded. Please free up iCloud space and retry."])
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return NSError(domain: "StorePass", code: 9202, userInfo: [NSLocalizedDescriptionKey: "CloudKit is temporarily unavailable. Please retry."])
        default:
            return normalizedError
        }
    }

    nonisolated private func normalizeCloudKitError(_ error: CKError) -> CKError {
        guard error.code == .partialFailure,
              let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
              !partial.isEmpty else {
            return error
        }

        let ckPartialErrors = partial.values.compactMap { $0 as? CKError }
        if ckPartialErrors.count == partial.count,
           let first = ckPartialErrors.first,
           ckPartialErrors.allSatisfy({ $0.code == first.code }) {
            return first
        }

        return error
    }

    nonisolated private func cloudKitIdentityMismatchErrorIfAny() -> CloudKitClientError? {
        guard let message = CloudKitIdentityMismatchState.message() else {
            return nil
        }
        return CloudKitClientError.invalidData(message)
    }

    private func databaseScopeName(_ database: CKDatabase) -> String {
        if database === privateDB { return "private" }
        if database === publicDB { return "public" }
        return "custom"
    }

    private func accountStatusName(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "available"
        case .noAccount:
            return "noAccount"
        case .restricted:
            return "restricted"
        case .couldNotDetermine:
            return "couldNotDetermine"
        case .temporarilyUnavailable:
            return "temporarilyUnavailable"
        @unknown default:
            return "unknown"
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

@MainActor
protocol UserProfileStoreProtocol {
    func fetchCanonicalProfile(userId: String) async throws -> UserProfile?
    func fetchPublicProfile(userId: String) async throws -> UserProfile?
    @discardableResult
    func upsertCanonicalProfile(_ profile: UserProfile, deletedAt: Date?) async throws -> UserProfile
    @discardableResult
    func upsertPublicProfile(_ profile: UserProfile, deletedAt: Date?) async throws -> UserProfile
    func upsertPublicProfileBestEffort(_ profile: UserProfile, deletedAt: Date?) async
    func resolvePublicUserRecordID(userId: String) async -> CKRecord.ID?
    func canonicalProfileEnsuringSeed(
        userId: String,
        role: UserRole,
        provider: String,
        fallbackName: String,
        fallbackEmail: String?
    ) async throws -> UserProfile
}

@MainActor
final class CloudKitUserProfileStore: UserProfileStoreProtocol {
    private let service: CloudKitService
    private let migrationPolicy = CloudKitMigrationPolicy()

    init(service: CloudKitService) {
        self.service = service
    }

    func fetchCanonicalProfile(userId: String) async throws -> UserProfile? {
        try await service.ensureCloudKitAvailable()
        AppLog.info("ProfileStore fetchCanonicalProfile started user=\(AppLog.redactIdentifier(userId))")
        guard let record = try await fetchAnyUserRecord(
            userId: userId,
            in: service.privateDB,
            tolerateLookupErrors: true,
            suppressPermissionErrors: true
        ) else {
            AppLog.info("ProfileStore fetchCanonicalProfile result=missing user=\(AppLog.redactIdentifier(userId))")
            return nil
        }
        let decoded = decodeUserProfile(record: record)
        AppLog.info(
            "ProfileStore fetchCanonicalProfile result=\(decoded == nil ? "decode_failed" : "found") user=\(AppLog.redactIdentifier(userId)) type=\(record.recordType)"
        )
        return decoded
    }

    func fetchPublicProfile(userId: String) async throws -> UserProfile? {
        try await service.ensureCloudKitAvailable()
        AppLog.info("ProfileStore fetchPublicProfile started user=\(AppLog.redactIdentifier(userId))")
        guard let record = try await fetchAnyUserRecord(
            userId: userId,
            in: service.publicDB,
            tolerateLookupErrors: true,
            suppressPermissionErrors: true
        ) else {
            AppLog.info("ProfileStore fetchPublicProfile result=missing user=\(AppLog.redactIdentifier(userId))")
            return nil
        }
        let decoded = decodeUserProfile(record: record)
        AppLog.info(
            "ProfileStore fetchPublicProfile result=\(decoded == nil ? "decode_failed" : "found") user=\(AppLog.redactIdentifier(userId)) type=\(record.recordType)"
        )
        return decoded
    }

    @discardableResult
    func upsertCanonicalProfile(_ profile: UserProfile, deletedAt: Date?) async throws -> UserProfile {
        try await service.ensureCloudKitAvailable()
        AppLog.info(
            "ProfileStore upsertCanonicalProfile started user=\(AppLog.redactIdentifier(profile.id)) role=\(profile.role.rawValue) active=\(profile.isActive)"
        )
        let savedRecord = try await upsertProfile(
            profile,
            deletedAt: deletedAt,
            in: service.privateDB,
            preferredRecordType: CKSchema.RecordType.user,
            fallbackToLegacyType: true
        )
        guard let savedProfile = decodeUserProfile(record: savedRecord) else {
            throw CloudKitClientError.invalidData("Failed to decode canonical user profile.")
        }
        AppLog.info(
            "ProfileStore upsertCanonicalProfile success user=\(AppLog.redactIdentifier(profile.id)) type=\(savedRecord.recordType)"
        )
        return savedProfile
    }

    @discardableResult
    func upsertPublicProfile(_ profile: UserProfile, deletedAt: Date?) async throws -> UserProfile {
        try await service.ensureCloudKitAvailable()
        AppLog.info(
            "ProfileStore upsertPublicProfile started user=\(AppLog.redactIdentifier(profile.id)) role=\(profile.role.rawValue) active=\(profile.isActive)"
        )
        let savedRecord = try await upsertProfile(
            profile,
            deletedAt: deletedAt,
            in: service.publicDB,
            preferredRecordType: CKSchema.RecordType.user,
            fallbackToLegacyType: true
        )
        guard let savedProfile = decodeUserProfile(record: savedRecord) else {
            throw CloudKitClientError.invalidData("Failed to decode mirrored public user profile.")
        }
        AppLog.info(
            "ProfileStore upsertPublicProfile success user=\(AppLog.redactIdentifier(profile.id)) type=\(savedRecord.recordType)"
        )
        return savedProfile
    }

    func upsertPublicProfileBestEffort(_ profile: UserProfile, deletedAt: Date?) async {
        AppLog.info("ProfileStore upsertPublicProfileBestEffort started user=\(AppLog.redactIdentifier(profile.id))")
        do {
            _ = try await upsertPublicProfile(profile, deletedAt: deletedAt)
            AppLog.info("ProfileStore upsertPublicProfileBestEffort success user=\(AppLog.redactIdentifier(profile.id))")
        } catch {
            AppLog.warning(
                "Public profile mirror skipped for user=\(AppLog.redactIdentifier(profile.id)): \(AppLog.sanitize(error.localizedDescription))"
            )
        }
    }

    func resolvePublicUserRecordID(userId: String) async -> CKRecord.ID? {
        AppLog.info("ProfileStore resolvePublicUserRecordID started user=\(AppLog.redactIdentifier(userId))")
        do {
            guard let record = try await fetchAnyUserRecord(
                userId: userId,
                in: service.publicDB,
                tolerateLookupErrors: true,
                suppressPermissionErrors: true
            ) else {
                AppLog.info("ProfileStore resolvePublicUserRecordID result=missing user=\(AppLog.redactIdentifier(userId))")
                return nil
            }
            AppLog.info("ProfileStore resolvePublicUserRecordID success user=\(AppLog.redactIdentifier(userId)) id=\(record.recordID.recordName)")
            return record.recordID
        } catch {
            AppLog.warning(
                "Unable to resolve public user record id for user=\(AppLog.redactIdentifier(userId)): \(AppLog.sanitize(error.localizedDescription))"
            )
            return nil
        }
    }

    func canonicalProfileEnsuringSeed(
        userId: String,
        role: UserRole,
        provider: String,
        fallbackName: String,
        fallbackEmail: String?
    ) async throws -> UserProfile {
        AppLog.info(
            "ProfileStore canonicalProfileEnsuringSeed started user=\(AppLog.redactIdentifier(userId)) role=\(role.rawValue)"
        )
        if let canonical = try await fetchCanonicalProfile(userId: userId) {
            AppLog.info("ProfileStore canonicalProfileEnsuringSeed used canonical profile for user=\(AppLog.redactIdentifier(userId))")
            return canonical
        }

        if let publicProfile = try await fetchPublicProfile(userId: userId) {
            AppLog.info("ProfileStore canonicalProfileEnsuringSeed backfilling from public profile for user=\(AppLog.redactIdentifier(userId))")
            return try await upsertCanonicalProfile(publicProfile, deletedAt: nil)
        }

        let now = Date()
        let seededProfile = UserProfile(
            id: userId,
            name: fallbackName,
            email: normalizeEmail(fallbackEmail),
            role: role,
            createdAt: now,
            lastLoginAt: now,
            provider: provider,
            assignedStoreIds: [],
            isActive: true
        )

        AppLog.info("ProfileStore canonicalProfileEnsuringSeed creating new canonical seed for user=\(AppLog.redactIdentifier(userId))")
        return try await upsertCanonicalProfile(seededProfile, deletedAt: nil)
    }

    private func upsertProfile(
        _ profile: UserProfile,
        deletedAt: Date?,
        in database: CKDatabase,
        preferredRecordType: String,
        fallbackToLegacyType: Bool
    ) async throws -> CKRecord {
        let scope = databaseScopeName(database)
        AppLog.info(
            "ProfileStore upsertProfile started scope=\(scope) user=\(AppLog.redactIdentifier(profile.id)) preferredType=\(preferredRecordType)"
        )
        let existing = try await fetchAnyUserRecord(
            userId: profile.id,
            in: database,
            tolerateLookupErrors: true,
            suppressPermissionErrors: true
        )

        let recordID = CloudKitService.userRecordID(userId: profile.id)
        if let existing {
            AppLog.info(
                "ProfileStore upsertProfile updating existing record scope=\(scope) type=\(existing.recordType) id=\(existing.recordID.recordName)"
            )
            let record = populate(record: existing, with: profile, deletedAt: deletedAt)
            return try await service.save(record: record, in: database)
        }

        let primary = populate(
            record: CKRecord(recordType: preferredRecordType, recordID: recordID),
            with: profile,
            deletedAt: deletedAt
        )

        do {
            AppLog.info("ProfileStore upsertProfile creating primary type=\(preferredRecordType) scope=\(scope)")
            return try await service.save(record: primary, in: database)
        } catch let primaryError {
            guard fallbackToLegacyType,
                  preferredRecordType == CKSchema.RecordType.user,
                  shouldFallbackToLegacyAfterPrimarySaveFailure(primaryError) else {
                AppLog.error(
                    "ProfileStore upsertProfile primary save failed without legacy fallback scope=\(scope)",
                    error: primaryError
                )
                throw primaryError
            }

            AppLog.warning("ProfileStore upsertProfile primary save failed, attempting legacy Users fallback scope=\(scope)")
            let legacy = populate(
                record: CKRecord(recordType: CKSchema.RecordType.legacyUsers, recordID: recordID),
                with: profile,
                deletedAt: deletedAt
            )
            do {
                return try await service.save(record: legacy, in: database)
            } catch let legacyError {
                // Do not let protected or unavailable legacy `Users` writes mask the primary failure.
                if shouldSuppress(legacyError, tolerateLookupErrors: true, suppressPermissionErrors: true) {
                    AppLog.warning("ProfileStore upsertProfile suppressing legacy fallback error and rethrowing primary error scope=\(scope)")
                    throw primaryError
                }
                throw legacyError
            }
        }
    }

    private func populate(record: CKRecord, with profile: UserProfile, deletedAt: Date?) -> CKRecord {
        let now = Date()

        record[CKSchema.UserField.userId] = profile.id as CKRecordValue
        record[CKSchema.UserField.role] = profile.role.rawValue as CKRecordValue
        record[CKSchema.UserField.name] = profile.name as CKRecordValue

        if let normalizedEmail = normalizeEmail(profile.email) {
            record[CKSchema.UserField.email] = normalizedEmail as CKRecordValue
        } else {
            record[CKSchema.UserField.email] = nil
        }

        record[CKSchema.UserField.isActive] = NSNumber(value: profile.isActive)
        record[CKSchema.UserField.provider] = profile.provider as CKRecordValue
        record[CKSchema.UserField.assignedStoreIds] = profile.assignedStoreIds.sorted() as CKRecordValue
        if let hourlyRateCents = profile.hourlyRateCents {
            record[CKSchema.UserField.hourlyRateCents] = NSNumber(value: max(hourlyRateCents, 0))
        } else {
            record[CKSchema.UserField.hourlyRateCents] = nil
        }
        if let expectedStartMinutes = profile.expectedStartMinutesFromMidnight {
            let clamped = min(max(expectedStartMinutes, 0), 1_439)
            record[CKSchema.UserField.expectedStartMinutesFromMidnight] = NSNumber(value: clamped)
        } else {
            record[CKSchema.UserField.expectedStartMinutesFromMidnight] = nil
        }

        let createdAt = record.date(CKSchema.UserField.createdAt) ?? profile.createdAt
        record[CKSchema.UserField.createdAt] = createdAt as CKRecordValue
        record[CKSchema.UserField.updatedAt] = now as CKRecordValue

        if let deletedAt {
            record[CKSchema.UserField.deletedAt] = deletedAt as CKRecordValue
        } else if profile.isActive {
            record[CKSchema.UserField.deletedAt] = nil
        }

        return record
    }

    private func fetchAnyUserRecord(
        userId: String,
        in database: CKDatabase,
        tolerateLookupErrors: Bool,
        suppressPermissionErrors: Bool
    ) async throws -> CKRecord? {
        let recordID = CloudKitService.userRecordID(userId: userId)
        let scope = databaseScopeName(database)
        AppLog.info("ProfileStore fetchAnyUserRecord started scope=\(scope) user=\(AppLog.redactIdentifier(userId)) recordID=\(recordID.recordName)")

        do {
            if let direct = try await service.fetchRecord(with: recordID, in: database) {
                AppLog.info("ProfileStore fetchAnyUserRecord hit direct record scope=\(scope) type=\(direct.recordType)")
                return direct
            }
        } catch {
            if shouldSuppress(error, tolerateLookupErrors: tolerateLookupErrors, suppressPermissionErrors: suppressPermissionErrors) {
                AppLog.warning("ProfileStore fetchAnyUserRecord suppressed direct lookup error scope=\(scope): \(AppLog.sanitize(error.localizedDescription))")
                return nil
            }
            throw error
        }

        if let userRecord = try await queryFirst(
            recordType: CKSchema.RecordType.user,
            userId: userId,
            in: database,
            tolerateLookupErrors: tolerateLookupErrors,
            suppressPermissionErrors: suppressPermissionErrors
        ) {
            AppLog.info("ProfileStore fetchAnyUserRecord hit query record type=User scope=\(scope)")
            return userRecord
        }

        if let legacyUserRecord = try await queryFirst(
            recordType: CKSchema.RecordType.legacyUsers,
            userId: userId,
            in: database,
            tolerateLookupErrors: tolerateLookupErrors,
            suppressPermissionErrors: suppressPermissionErrors
        ) {
            AppLog.info("ProfileStore fetchAnyUserRecord hit query record type=Users scope=\(scope)")
            return legacyUserRecord
        }

        AppLog.info("ProfileStore fetchAnyUserRecord result=missing scope=\(scope) user=\(AppLog.redactIdentifier(userId))")
        return nil
    }

    private func queryFirst(
        recordType: String,
        userId: String,
        in database: CKDatabase,
        tolerateLookupErrors: Bool,
        suppressPermissionErrors: Bool
    ) async throws -> CKRecord? {
        let scope = databaseScopeName(database)
        AppLog.info("ProfileStore queryFirst started scope=\(scope) type=\(recordType) user=\(AppLog.redactIdentifier(userId))")
        do {
            let records = try await service.queryRecords(
                recordType: recordType,
                predicate: NSPredicate(format: "%K == %@", CKSchema.UserField.userId, userId),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.UserField.updatedAt, ascending: false)],
                resultsLimit: 1,
                in: database
            )
            AppLog.info("ProfileStore queryFirst finished scope=\(scope) type=\(recordType) count=\(records.count)")
            return records.first
        } catch {
            if shouldSuppress(error, tolerateLookupErrors: tolerateLookupErrors, suppressPermissionErrors: suppressPermissionErrors) {
                AppLog.warning(
                    "ProfileStore queryFirst suppressed error scope=\(scope) type=\(recordType): \(AppLog.sanitize(error.localizedDescription))"
                )
                return nil
            }
            throw error
        }
    }

    private func shouldSuppress(
        _ error: Error,
        tolerateLookupErrors: Bool,
        suppressPermissionErrors: Bool
    ) -> Bool {
        migrationPolicy.shouldSuppress(
            error,
            tolerateLookupErrors: tolerateLookupErrors,
            suppressPermissionErrors: suppressPermissionErrors
        )
    }

    private func shouldFallbackToLegacyAfterPrimarySaveFailure(_ error: Error) -> Bool {
        migrationPolicy.shouldFallbackToLegacyAfterPrimarySaveFailure(error)
    }

    private func isSchemaMismatch(_ error: Error) -> Bool {
        migrationPolicy.isSchemaMismatch(error)
    }

    private func normalizeEmail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private func databaseScopeName(_ database: CKDatabase) -> String {
        if database === service.privateDB { return "private" }
        if database === service.publicDB { return "public" }
        return "custom"
    }
}

final class CloudKitUserRepository: UserRepositoryProtocol {
    private let service: CloudKitService
    private let profileStore: UserProfileStoreProtocol

    init(service: CloudKitService, profileStore: UserProfileStoreProtocol) {
        self.service = service
        self.profileStore = profileStore
    }

    func fetchUser(id: String) async throws -> UserProfile? {
        try await service.ensureCloudKitAvailable()

        if let canonical = try await profileStore.fetchCanonicalProfile(userId: id) {
            return canonical
        }

        if let publicProfile = try await profileStore.fetchPublicProfile(userId: id) {
            _ = try? await profileStore.upsertCanonicalProfile(publicProfile, deletedAt: nil)
            return publicProfile
        }

        return nil
    }

    func upsertUser(_ user: UserProfile) async throws {
        try await service.ensureCloudKitAvailable()
        let saved = try await profileStore.upsertCanonicalProfile(user, deletedAt: user.isActive ? nil : Date())
        await profileStore.upsertPublicProfileBestEffort(saved, deletedAt: saved.isActive ? nil : Date())
    }
}

final class CloudKitEmployeeManagementRepository: EmployeeManagementRepositoryProtocol {
    private let service: CloudKitService
    private let profileStore: UserProfileStoreProtocol
    private static let localFallbackStoresKey = "storecheck.local_manager_stores.v1"
    private static let localFallbackEmployeeLinksKey = "storecheck.local_employee_store_links.v1"
    private static let localCheckInsKey = "storecheck.local_checkins.v1"
    private static let localPhotoDirectoryName = "storecheck_local_photos"

    init(service: CloudKitService, profileStore: UserProfileStoreProtocol) {
        self.service = service
        self.profileStore = profileStore
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        try await service.ensureCloudKitAvailable()
        let localStores = localFallbackStores(managerId: managerId)
        if !localStores.isEmpty {
            AppLog.warning("Employee management using local store fallback manager=\(AppLog.redactIdentifier(managerId)) count=\(localStores.count)")
        }

        if service.isCloudKitIdentityMismatchDetected {
            return localStores
        }

        var publicStores: [Store] = []
        var publicRecovered = false

        do {
            publicStores = try await queryManagerStores(managerId: managerId, in: service.publicDB)
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            publicRecovered = true
            AppLog.warning("Public manager store fetch failed in employee management: \(AppLog.sanitize(error.localizedDescription))")
        }

        var privateStores: [Store] = []
        var privateRecovered = false
        do {
            privateStores = try await queryManagerStores(managerId: managerId, in: service.privateDB)
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            privateRecovered = true
            AppLog.warning("Private manager store fetch failed in employee management: \(AppLog.sanitize(error.localizedDescription))")
        }

        let queriedStores = mergeStores(preferred: privateStores, fallback: publicStores)
        if queriedStores.isEmpty, publicRecovered || privateRecovered {
            return localStores
        }

        return mergeStores(preferred: queriedStores, fallback: localStores)
    }

    func fetchEmployeesForManagerStores(managerStores: [Store]) async throws -> [EmployeeSummary] {
        try await service.ensureCloudKitAvailable()
        guard !managerStores.isEmpty else { return [] }
        let identityMismatchDetected = service.isCloudKitIdentityMismatchDetected

        let storesById = Dictionary(uniqueKeysWithValues: managerStores.map { ($0.id, $0) })
        let managedStoreIds = Set(storesById.keys)
        var storeIdsByEmployee: [String: Set<String>] = [:]
        var membershipIdentityHints: [String: (name: String?, email: String?)] = [:]

        for store in managerStores {
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.storeId, store.id),
                NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.status, CKSchema.MemberStatus.active)
            ])

            let membershipRecords: [CKRecord]
            do {
                membershipRecords = try await service.queryRecords(recordType: CKSchema.RecordType.storeMember, predicate: predicate)
            } catch {
                guard isRecoverableManagerStoreError(error) else {
                    throw error
                }
                AppLog.warning("Membership fetch skipped for store=\(store.id): \(AppLog.sanitize(error.localizedDescription))")
                continue
            }
            for record in membershipRecords {
                guard let employeeId = record.string(CKSchema.StoreMemberField.employeeUserId) else { continue }
                storeIdsByEmployee[employeeId, default: []].insert(store.id)

                let existingHint = membershipIdentityHints[employeeId]
                membershipIdentityHints[employeeId] = (
                    name: existingHint?.name ?? record.string(CKSchema.StoreMemberField.employeeName),
                    email: existingHint?.email ?? record.string(CKSchema.StoreMemberField.employeeEmail)
                )
            }
        }

        let localLinks = localEmployeeStoreLinks(forManagedStoreIds: managedStoreIds)
        for (employeeId, storeIds) in localLinks {
            storeIdsByEmployee[employeeId, default: []].formUnion(storeIds)
        }
        let localCheckInHints = localIdentityHintsFromCheckIns(forManagedStoreIds: managedStoreIds)
        for (employeeId, hint) in localCheckInHints {
            if let storeIds = hint.storeIds, !storeIds.isEmpty {
                storeIdsByEmployee[employeeId, default: []].formUnion(storeIds)
            }
        }
        let cloudCheckInHints = identityMismatchDetected
            ? [:]
            : await cloudIdentityHintsFromCheckIns(forManagedStoreIds: managedStoreIds)
        for (employeeId, hint) in cloudCheckInHints {
            if let storeIds = hint.storeIds, !storeIds.isEmpty {
                storeIdsByEmployee[employeeId, default: []].formUnion(storeIds)
            }
        }

        var summaries: [EmployeeSummary] = []
        for (employeeId, memberships) in storeIdsByEmployee {
            let fallback = membershipIdentityHints[employeeId]
            let linkHint = localIdentityHintFromLinks(employeeId: employeeId)
            let localCheckInHint = localCheckInHints[employeeId]
            let cloudCheckInHint = cloudCheckInHints[employeeId]
            let resolvedProfile: UserProfile?
            if identityMismatchDetected {
                resolvedProfile = nil
            } else {
                do {
                    resolvedProfile = try await resolveAnyProfile(userId: employeeId)
                } catch {
                    AppLog.warning("Employee profile lookup failed for user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))")
                    resolvedProfile = nil
                }
            }

            if let resolvedProfile, resolvedProfile.role == .manager {
                continue
            }

            let sortedIds = memberships.sorted()
            let storeNames = sortedIds.compactMap { storesById[$0]?.name }
            let displayName = preferredDisplayName(
                employeeId: employeeId,
                candidates: [
                    resolvedProfile?.name,
                    fallback?.name,
                    cloudCheckInHint?.name,
                    localCheckInHint?.name,
                    linkHint?.name
                ]
            )
            let displayEmail = preferredDisplayEmail(
                candidates: [
                    resolvedProfile?.email,
                    fallback?.email,
                    cloudCheckInHint?.email,
                    localCheckInHint?.email,
                    linkHint?.email
                ]
            )
            let hourlyRateCents = localHourlyRateCents(employeeId: employeeId) ?? resolvedProfile?.hourlyRateCents
            let expectedStartMinutes = localExpectedStartMinutes(employeeId: employeeId) ?? resolvedProfile?.expectedStartMinutesFromMidnight
            let localIsActive = localEmployeeIsActive(employeeId: employeeId)

            summaries.append(
                EmployeeSummary(
                    id: employeeId,
                    name: displayName,
                    email: displayEmail,
                    hourlyRateCents: hourlyRateCents,
                    expectedStartMinutesFromMidnight: expectedStartMinutes,
                    storeIds: sortedIds,
                    storeNames: storeNames,
                    userIsActive: localIsActive ?? resolvedProfile?.isActive ?? true,
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

    func updateEmployeeProfile(
        employeeId: String,
        name: String,
        hourlyRateCents: Int?,
        expectedStartMinutesFromMidnight: Int?
    ) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CloudKitClientError.invalidData("Employee name is required.")
        }

        if let hourlyRateCents, hourlyRateCents < 0 {
            throw CloudKitClientError.invalidData("Hourly salary must be zero or greater.")
        }
        if let expectedStartMinutesFromMidnight,
           !(0...1_439).contains(expectedStartMinutesFromMidnight) {
            throw CloudKitClientError.invalidData("Expected start time is invalid.")
        }

        let managerId = try service.requireCurrentUserId()
        let managerStores = try await fetchManagerStores(managerId: managerId)
        let managedStoreIds = Set(managerStores.map(\.id))
        guard !managedStoreIds.isEmpty else {
            throw CloudKitClientError.invalidData("Create a store before editing employees.")
        }

        let preservedEmail = localIdentityHintFromLinks(employeeId: employeeId)?.email
        setLocalEmployeeOverride(
            employeeId: employeeId,
            name: trimmedName,
            email: preservedEmail,
            hourlyRateCents: hourlyRateCents,
            expectedStartMinutesFromMidnight: expectedStartMinutesFromMidnight
        )

        if service.isCloudKitIdentityMismatchDetected {
            return
        }

        let existingProfile = try? await resolveAnyProfile(userId: employeeId)
        let fallbackRole = existingProfile?.role ?? .employee
        let provider = existingProfile?.provider ?? "apple"
        let existingEmail = existingProfile?.email
        var profile = try await profileStore.canonicalProfileEnsuringSeed(
            userId: employeeId,
            role: fallbackRole,
            provider: provider,
            fallbackName: trimmedName,
            fallbackEmail: existingEmail
        )
        profile.name = trimmedName
        profile.email = existingEmail
        profile.hourlyRateCents = hourlyRateCents
        profile.expectedStartMinutesFromMidnight = expectedStartMinutesFromMidnight
        profile.lastLoginAt = Date()

        do {
            _ = try await profileStore.upsertCanonicalProfile(profile, deletedAt: profile.isActive ? nil : Date())
            await profileStore.upsertPublicProfileBestEffort(profile, deletedAt: profile.isActive ? nil : Date())
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Employee profile update skipped for user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))")
        }

        do {
            let memberships = try await service.queryRecords(
                recordType: CKSchema.RecordType.storeMember,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.employeeUserId, employeeId),
                    NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.status, CKSchema.MemberStatus.active)
                ])
            )

            var recordsToSave: [CKRecord] = []
            for membership in memberships {
                guard let storeId = membership.string(CKSchema.StoreMemberField.storeId),
                      managedStoreIds.contains(storeId) else {
                    continue
                }

                membership[CKSchema.StoreMemberField.employeeName] = trimmedName as CKRecordValue
                membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue
                recordsToSave.append(membership)
            }

            if !recordsToSave.isEmpty {
                _ = try await service.modify(recordsToSave: recordsToSave, atomic: false)
            }
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Membership profile hints update skipped for user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    func removeEmployeeFromStore(storeId: String, employeeId: String) async throws {
        let currentUserId = try service.requireCurrentUserId()
        setLocalEmployeeStoreMembership(employeeId: employeeId, storeId: storeId, isActive: false)
        clearLocalStoreHistory(employeeId: employeeId, storeId: storeId)

        if service.isCloudKitIdentityMismatchDetected {
            return
        }

        do {
            try await service.ensureCloudKitAvailable()
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning(
                "Remove employee from store continuing with local-only fallback store=\(storeId) employee=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))"
            )
            return
        }

        do {
            try await assertStoreManagedByCurrentUser(storeId: storeId, expectedManagerId: currentUserId)

            let membershipId = CloudKitService.membershipRecordID(storeId: storeId, employeeId: employeeId)
            guard let membership = try await service.fetchRecord(with: membershipId) else {
                await recomputeAssignedStoresBestEffort(for: employeeId, context: "removeEmployeeFromStore")
                return
            }

            membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.removed as CKRecordValue
            membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue
            _ = try await service.save(record: membership)

            try await clearCloudStoreHistory(managerId: currentUserId, employeeId: employeeId, storeId: storeId)
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Remove employee from store recovered locally store=\(storeId) employee=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))")
        }

        await recomputeAssignedStoresBestEffort(for: employeeId, context: "removeEmployeeFromStore")
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

        let existingProfile = try await resolveAnyProfile(userId: employeeId)
        let publicEmployeeRecordID = await profileStore.resolvePublicUserRecordID(userId: employeeId)
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

            if let publicEmployeeRecordID {
                membership[CKSchema.StoreMemberField.employeeUserRef] = CKRecord.Reference(recordID: publicEmployeeRecordID, action: .none)
            } else {
                membership[CKSchema.StoreMemberField.employeeUserRef] = nil
            }

            if let existingProfile {
                membership[CKSchema.StoreMemberField.employeeName] = existingProfile.name as CKRecordValue
                if let email = existingProfile.email, !email.isEmpty {
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
        await recomputeAssignedStoresBestEffort(for: employeeId, context: "setEmployeeStoresForManager")
    }

    func setEmployeeActive(employeeId: String, isActive: Bool) async throws {
        try await service.ensureCloudKitAvailable()
        setLocalEmployeeActiveState(employeeId: employeeId, isActive: isActive)
        if !isActive {
            setLocalEmployeeStoreMemberships(employeeId: employeeId, activeStoreIds: [])
        }

        if service.isCloudKitIdentityMismatchDetected {
            return
        }

        let existingProfile = try? await resolveAnyProfile(userId: employeeId)
        let fallbackName = existingProfile?.name ?? "Employee"
        let fallbackEmail = existingProfile?.email
        let fallbackRole = existingProfile?.role ?? .employee
        let deletedAt = isActive ? nil : Date()

        do {
            var profile = try await profileStore.canonicalProfileEnsuringSeed(
                userId: employeeId,
                role: fallbackRole,
                provider: existingProfile?.provider ?? "apple",
                fallbackName: fallbackName,
                fallbackEmail: fallbackEmail
            )

            profile.isActive = isActive
            profile.lastLoginAt = Date()
            if !isActive {
                profile.assignedStoreIds = []
            }

            await persistProfileBestEffort(profile, deletedAt: deletedAt, context: "setEmployeeActive")
        } catch {
            AppLog.warning(
                "Employee profile activation sync skipped user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))"
            )
        }

        do {
            var recordsToSave: [CKRecord] = []
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

            if !recordsToSave.isEmpty {
                _ = try await service.modify(recordsToSave: recordsToSave)
            }
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Set employee active recovered locally user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))")
        }

        if isActive {
            await recomputeAssignedStoresBestEffort(for: employeeId, context: "setEmployeeActive")
        }
    }

    func fetchStoreActivityFeed(managerId: String, storeId: String, limit: Int) async throws -> [StoreActivityEvent] {
        let currentUserId = try service.requireCurrentUserId()
        guard currentUserId == managerId else {
            throw CloudKitClientError.unauthorized
        }

        let stores = try await fetchManagerStores(managerId: managerId)
        guard let store = stores.first(where: { $0.id == storeId }) else {
            throw CloudKitClientError.missingRecord("Store not found.")
        }

        if service.isCloudKitIdentityMismatchDetected {
            return Array(localStoreActivityFeed(store: store).prefix(limit))
        }

        try await service.ensureCloudKitAvailable()

        var events: [StoreActivityEvent] = []

        do {
            let checkInRecords = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, storeId),
                    NSPredicate(format: "%K == %@", CKSchema.CheckInField.managerUserId, managerId)
                ]),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.checkInAt, ascending: false)],
                resultsLimit: max(limit * 3, 120)
            )

            for record in checkInRecords {
                guard let sessionId = record.string(CKSchema.CheckInField.sessionId),
                      let checkInAt = record.date(CKSchema.CheckInField.checkInAt) else {
                    continue
                }
                let employeeId = record.string(CKSchema.CheckInField.employeeUserId)
                let employeeName = record.string(CKSchema.CheckInField.employeeName)
                let employeeEmail = record.string(CKSchema.CheckInField.employeeEmail)
                events.append(
                    StoreActivityEvent(
                        id: "checkin_\(sessionId)",
                        storeId: storeId,
                        storeName: store.name,
                        employeeId: employeeId,
                        employeeName: employeeName,
                        employeeEmail: employeeEmail,
                        kind: .checkedIn,
                        occurredAt: checkInAt,
                        checkInId: sessionId
                    )
                )

                if let checkOutAt = record.date(CKSchema.CheckInField.checkOutAt) {
                    events.append(
                        StoreActivityEvent(
                            id: "checkout_\(sessionId)",
                            storeId: storeId,
                            storeName: store.name,
                            employeeId: employeeId,
                            employeeName: employeeName,
                            employeeEmail: employeeEmail,
                            kind: .checkedOut,
                            occurredAt: checkOutAt,
                            checkInId: sessionId
                        )
                    )
                }
            }
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            events.append(contentsOf: localStoreActivityFeed(store: store))
        }

        do {
            let membershipRecords = try await service.queryRecords(
                recordType: CKSchema.RecordType.storeMember,
                predicate: NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.storeId, storeId),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.StoreMemberField.updatedAt, ascending: false)],
                resultsLimit: max(limit * 2, 80)
            )

            for record in membershipRecords {
                guard let employeeId = record.string(CKSchema.StoreMemberField.employeeUserId), !employeeId.isEmpty else {
                    continue
                }
                let employeeName = record.string(CKSchema.StoreMemberField.employeeName)
                let employeeEmail = record.string(CKSchema.StoreMemberField.employeeEmail)
                let status = record.string(CKSchema.StoreMemberField.status) ?? CKSchema.MemberStatus.active

                if let joinedAt = record.date(CKSchema.StoreMemberField.joinedAt), status == CKSchema.MemberStatus.active {
                    events.append(
                        StoreActivityEvent(
                            id: "joined_\(storeId)_\(employeeId)",
                            storeId: storeId,
                            storeName: store.name,
                            employeeId: employeeId,
                            employeeName: employeeName,
                            employeeEmail: employeeEmail,
                            kind: .employeeJoined,
                            occurredAt: joinedAt,
                            checkInId: nil
                        )
                    )
                }

                if status == CKSchema.MemberStatus.removed {
                    let removedAt = record.date(CKSchema.StoreMemberField.updatedAt) ?? Date.distantPast
                    events.append(
                        StoreActivityEvent(
                            id: "removed_\(storeId)_\(employeeId)_\(removedAt.timeIntervalSince1970)",
                            storeId: storeId,
                            storeName: store.name,
                            employeeId: employeeId,
                            employeeName: employeeName,
                            employeeEmail: employeeEmail,
                            kind: .employeeRemoved,
                            occurredAt: removedAt,
                            checkInId: nil
                        )
                    )
                }
            }
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            events.append(contentsOf: localMembershipActivityFeed(store: store))
        }

        let deduped = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) }).values
        return Array(deduped.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit))
    }

    private func assertStoreManagedByCurrentUser(storeId: String, expectedManagerId: String) async throws {
        let recordID = CloudKitService.storeRecordID(storeId: storeId)

        if let privateRecord = try await service.fetchRecord(with: recordID, in: service.privateDB) {
            guard privateRecord.string(CKSchema.StoreField.managerUserId) == expectedManagerId else {
                throw CloudKitClientError.unauthorized
            }
            return
        }

        do {
            if let publicRecord = try await service.fetchRecord(with: recordID) {
                guard publicRecord.string(CKSchema.StoreField.managerUserId) == expectedManagerId else {
                    throw CloudKitClientError.unauthorized
                }
                return
            }
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Public store ownership check skipped: \(AppLog.sanitize(error.localizedDescription))")
        }

        throw CloudKitClientError.missingRecord("Store could not be found.")
    }

    private func queryManagerStores(managerId: String, in database: CKDatabase) async throws -> [Store] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K == %@", CKSchema.StoreField.managerUserId, managerId),
            NSPredicate(format: "%K == %@", CKSchema.StoreField.isActive, NSNumber(value: true))
        ])

        let records = try await service.queryRecords(
            recordType: CKSchema.RecordType.store,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: CKSchema.StoreField.name, ascending: true)],
            in: database
        )

        return records.compactMap(decodeStore(record:))
    }

    private func mergeStores(preferred: [Store], fallback: [Store]) -> [Store] {
        var mergedById = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        for store in preferred {
            mergedById[store.id] = store
        }
        return mergedById.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isRecoverableManagerStoreError(_ error: Error) -> Bool {
        if shouldUseLocalStoreFallback(for: error) {
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

    private func shouldUseLocalStoreFallback(for error: Error) -> Bool {
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

    private struct LocalFallbackPayload: Codable {
        var storesByManagerId: [String: [Store]] = [:]
    }

    private struct LocalEmployeeStoreLinksPayload: Codable {
        var storeIdsByEmployeeId: [String: [String]] = [:]
        var employeeNameById: [String: String]? = nil
        var employeeEmailById: [String: String]? = nil
        var employeeHourlyRateCentsById: [String: Int]? = nil
        var employeeExpectedStartMinutesById: [String: Int]? = nil
        var employeeIsActiveById: [String: Bool]? = nil
    }

    private struct LocalCheckInPayload: Codable {
        var checkInsByEmployeeId: [String: [CheckIn]] = [:]
    }

    private struct LocalEmployeeIdentityHint {
        var name: String?
        var email: String?
        var storeIds: Set<String>?
    }

    private func localFallbackStores(managerId: String) -> [Store] {
        let payload = loadLocalFallbackPayload()
        let stores = payload.storesByManagerId[managerId] ?? []
        return stores
            .filter(\.isActive)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func loadLocalFallbackPayload() -> LocalFallbackPayload {
        guard let data = UserDefaults.standard.data(forKey: Self.localFallbackStoresKey) else {
            return LocalFallbackPayload()
        }
        do {
            return try JSONDecoder().decode(LocalFallbackPayload.self, from: data)
        } catch {
            AppLog.warning("Employee management local fallback decode failed: \(AppLog.sanitize(error.localizedDescription))")
            return LocalFallbackPayload()
        }
    }

    private func localEmployeeStoreLinks(forManagedStoreIds managedStoreIds: Set<String>) -> [String: Set<String>] {
        guard !managedStoreIds.isEmpty else { return [:] }
        let payload = loadLocalEmployeeStoreLinksPayload()
        var result: [String: Set<String>] = [:]
        for (employeeId, storeIds) in payload.storeIdsByEmployeeId {
            let active = Set(storeIds).intersection(managedStoreIds)
            if !active.isEmpty {
                result[employeeId] = active
            }
        }
        return result
    }

    private func loadLocalEmployeeStoreLinksPayload() -> LocalEmployeeStoreLinksPayload {
        guard let data = UserDefaults.standard.data(forKey: Self.localFallbackEmployeeLinksKey) else {
            return LocalEmployeeStoreLinksPayload()
        }
        do {
            return try JSONDecoder().decode(LocalEmployeeStoreLinksPayload.self, from: data)
        } catch {
            AppLog.warning("Employee link local fallback decode failed: \(AppLog.sanitize(error.localizedDescription))")
            return LocalEmployeeStoreLinksPayload()
        }
    }

    private func localIdentityHintFromLinks(employeeId: String) -> LocalEmployeeIdentityHint? {
        let payload = loadLocalEmployeeStoreLinksPayload()
        let name = payload.employeeNameById?[employeeId]
        let email = payload.employeeEmailById?[employeeId]
        guard name != nil || email != nil else {
            return nil
        }
        return LocalEmployeeIdentityHint(name: name, email: email, storeIds: nil)
    }

    private func localHourlyRateCents(employeeId: String) -> Int? {
        let payload = loadLocalEmployeeStoreLinksPayload()
        return payload.employeeHourlyRateCentsById?[employeeId]
    }

    private func localExpectedStartMinutes(employeeId: String) -> Int? {
        let payload = loadLocalEmployeeStoreLinksPayload()
        return payload.employeeExpectedStartMinutesById?[employeeId]
    }

    private func localEmployeeIsActive(employeeId: String) -> Bool? {
        let payload = loadLocalEmployeeStoreLinksPayload()
        return payload.employeeIsActiveById?[employeeId]
    }

    private func setLocalEmployeeOverride(
        employeeId: String,
        name: String,
        email: String?,
        hourlyRateCents: Int?,
        expectedStartMinutesFromMidnight: Int?
    ) {
        var payload = loadLocalEmployeeStoreLinksPayload()
        var namesById = payload.employeeNameById ?? [:]
        var emailsById = payload.employeeEmailById ?? [:]
        var hourlyRatesById = payload.employeeHourlyRateCentsById ?? [:]
        var expectedStartsById = payload.employeeExpectedStartMinutesById ?? [:]

        namesById[employeeId] = name
        if let email {
            emailsById[employeeId] = email
        } else {
            emailsById.removeValue(forKey: employeeId)
        }

        if let hourlyRateCents {
            hourlyRatesById[employeeId] = hourlyRateCents
        } else {
            hourlyRatesById.removeValue(forKey: employeeId)
        }

        if let expectedStartMinutesFromMidnight {
            expectedStartsById[employeeId] = min(max(expectedStartMinutesFromMidnight, 0), 1_439)
        } else {
            expectedStartsById.removeValue(forKey: employeeId)
        }

        payload.employeeNameById = namesById
        payload.employeeEmailById = emailsById
        payload.employeeHourlyRateCentsById = hourlyRatesById
        payload.employeeExpectedStartMinutesById = expectedStartsById

        do {
            let data = try JSONEncoder().encode(payload)
            UserDefaults.standard.set(data, forKey: Self.localFallbackEmployeeLinksKey)
        } catch {
            AppLog.warning("Employee override local fallback encode failed: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func setLocalEmployeeStoreMembership(employeeId: String, storeId: String, isActive: Bool) {
        var payload = loadLocalEmployeeStoreLinksPayload()
        var storeIdsByEmployee = payload.storeIdsByEmployeeId
        var storeIds = Set(storeIdsByEmployee[employeeId] ?? [])
        if isActive {
            storeIds.insert(storeId)
        } else {
            storeIds.remove(storeId)
        }
        storeIdsByEmployee[employeeId] = Array(storeIds).sorted()
        payload.storeIdsByEmployeeId = storeIdsByEmployee
        saveLocalEmployeeStoreLinksPayload(payload)
    }

    private func setLocalEmployeeStoreMemberships(employeeId: String, activeStoreIds: [String]) {
        var payload = loadLocalEmployeeStoreLinksPayload()
        payload.storeIdsByEmployeeId[employeeId] = Array(Set(activeStoreIds)).sorted()
        saveLocalEmployeeStoreLinksPayload(payload)
    }

    private func setLocalEmployeeActiveState(employeeId: String, isActive: Bool) {
        var payload = loadLocalEmployeeStoreLinksPayload()
        var map = payload.employeeIsActiveById ?? [:]
        map[employeeId] = isActive
        payload.employeeIsActiveById = map
        saveLocalEmployeeStoreLinksPayload(payload)
    }

    private func saveLocalEmployeeStoreLinksPayload(_ payload: LocalEmployeeStoreLinksPayload) {
        do {
            let data = try JSONEncoder().encode(payload)
            UserDefaults.standard.set(data, forKey: Self.localFallbackEmployeeLinksKey)
        } catch {
            AppLog.warning("Employee link local fallback encode failed: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func localIdentityHintsFromCheckIns(forManagedStoreIds managedStoreIds: Set<String>) -> [String: LocalEmployeeIdentityHint] {
        guard !managedStoreIds.isEmpty else { return [:] }
        let payload = loadLocalCheckInPayload()
        var hints: [String: LocalEmployeeIdentityHint] = [:]

        for (employeeId, checkIns) in payload.checkInsByEmployeeId {
            let relevant = checkIns.filter { managedStoreIds.contains($0.storeId) }
            guard !relevant.isEmpty else { continue }
            let existing = hints[employeeId]
            let firstNamed = relevant.first { !$0.employeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let firstEmail = relevant.first { ($0.employeeEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }?.employeeEmail
            let names = existing?.name ?? firstNamed?.employeeName
            let email = existing?.email ?? firstEmail
            let stores = Set(relevant.map(\.storeId)).union(existing?.storeIds ?? [])
            hints[employeeId] = LocalEmployeeIdentityHint(name: names, email: email, storeIds: stores)
        }

        return hints
    }

    private func loadLocalCheckInPayload() -> LocalCheckInPayload {
        guard let data = UserDefaults.standard.data(forKey: Self.localCheckInsKey) else {
            return LocalCheckInPayload()
        }
        do {
            return try JSONDecoder().decode(LocalCheckInPayload.self, from: data)
        } catch {
            AppLog.warning("Local check-in identity fallback decode failed: \(AppLog.sanitize(error.localizedDescription))")
            return LocalCheckInPayload()
        }
    }

    private func saveLocalCheckInPayload(_ payload: LocalCheckInPayload) {
        do {
            let data = try JSONEncoder().encode(payload)
            UserDefaults.standard.set(data, forKey: Self.localCheckInsKey)
        } catch {
            AppLog.warning("Local check-in payload encode failed: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func clearCloudStoreHistory(managerId: String, employeeId: String, storeId: String) async throws {
        _ = managerId
        let records = try await service.queryRecords(
            recordType: CKSchema.RecordType.checkInSession,
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, employeeId),
                NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, storeId)
            ])
        )

        let recordIDs = records.map(\.recordID)
        guard !recordIDs.isEmpty else { return }
        _ = try await service.modify(recordsToSave: [], recordIDsToDelete: recordIDs, atomic: false)
    }

    private func clearLocalStoreHistory(employeeId: String, storeId: String) {
        var payload = loadLocalCheckInPayload()
        var sessions = payload.checkInsByEmployeeId[employeeId] ?? []
        let removed = sessions.filter { $0.storeId == storeId }
        sessions.removeAll { $0.storeId == storeId }
        payload.checkInsByEmployeeId[employeeId] = sessions
        saveLocalCheckInPayload(payload)

        for session in removed {
            let checkInToken = "checkin_\(session.id).jpg"
            let checkOutToken = "checkout_\(session.id).jpg"
            try? FileManager.default.removeItem(at: localPhotoFileURL(token: checkInToken))
            try? FileManager.default.removeItem(at: localPhotoFileURL(token: checkOutToken))
        }
    }

    private func localPhotoFileURL(token: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.localPhotoDirectoryName, isDirectory: true)
            .appendingPathComponent(token)
    }

    private func localStoreActivityFeed(store: Store) -> [StoreActivityEvent] {
        let payload = loadLocalCheckInPayload()
        var events: [StoreActivityEvent] = []
        for sessions in payload.checkInsByEmployeeId.values {
            for session in sessions where session.storeId == store.id {
                events.append(
                    StoreActivityEvent(
                        id: "checkin_\(session.id)",
                        storeId: store.id,
                        storeName: store.name,
                        employeeId: session.employeeId,
                        employeeName: session.employeeName,
                        employeeEmail: session.employeeEmail,
                        kind: .checkedIn,
                        occurredAt: session.checkInTime,
                        checkInId: session.id
                    )
                )
                if let checkOutTime = session.checkOutTime {
                    events.append(
                        StoreActivityEvent(
                            id: "checkout_\(session.id)",
                            storeId: store.id,
                            storeName: store.name,
                            employeeId: session.employeeId,
                            employeeName: session.employeeName,
                            employeeEmail: session.employeeEmail,
                            kind: .checkedOut,
                            occurredAt: checkOutTime,
                            checkInId: session.id
                        )
                    )
                }
            }
        }
        return events.sorted { $0.occurredAt > $1.occurredAt }
    }

    private func localMembershipActivityFeed(store: Store) -> [StoreActivityEvent] {
        let payload = loadLocalEmployeeStoreLinksPayload()
        var events: [StoreActivityEvent] = []
        let names = payload.employeeNameById ?? [:]
        let emails = payload.employeeEmailById ?? [:]
        for (employeeId, storeIds) in payload.storeIdsByEmployeeId where storeIds.contains(store.id) {
            events.append(
                StoreActivityEvent(
                    id: "joined_\(store.id)_\(employeeId)",
                    storeId: store.id,
                    storeName: store.name,
                    employeeId: employeeId,
                    employeeName: names[employeeId],
                    employeeEmail: emails[employeeId],
                    kind: .employeeJoined,
                    occurredAt: Date.distantPast,
                    checkInId: nil
                )
            )
        }
        return events
    }

    private func localFallbackEmployeeName(employeeId: String) -> String {
        let suffix = employeeId.suffix(4)
        return "Employee \(suffix)"
    }

    private func normalizeEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else {
            return nil
        }
        return trimmed.lowercased()
    }

    private func preferredDisplayName(employeeId: String, candidates: [String?]) -> String {
        let normalizedCandidates = candidates.compactMap(normalizedIdentityValue)
        if let strongName = normalizedCandidates.first(where: { !isWeakDisplayName($0, employeeId: employeeId) }) {
            return strongName
        }
        if let fallbackName = normalizedCandidates.first {
            return fallbackName
        }
        return localFallbackEmployeeName(employeeId: employeeId)
    }

    private func preferredDisplayEmail(candidates: [String?]) -> String? {
        candidates.compactMap(normalizedIdentityValue).first
    }

    private func normalizedIdentityValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isWeakDisplayName(_ value: String, employeeId: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        if lower == "storepass user" || lower == "employee" {
            return true
        }

        if lower == localFallbackEmployeeName(employeeId: employeeId).lowercased() {
            return true
        }

        if lower.hasPrefix("employee ") {
            return true
        }

        return false
    }

    private func cloudIdentityHintsFromCheckIns(forManagedStoreIds managedStoreIds: Set<String>) async -> [String: LocalEmployeeIdentityHint] {
        guard !managedStoreIds.isEmpty else { return [:] }

        let predicate = NSPredicate(
            format: "%K IN %@",
            CKSchema.CheckInField.storeId,
            Array(managedStoreIds)
        )

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: predicate,
                sortDescriptors: [NSSortDescriptor(key: CKSchema.CheckInField.updatedAt, ascending: false)],
                resultsLimit: 500
            )
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                AppLog.warning("Cloud check-in identity hint fetch failed: \(AppLog.sanitize(error.localizedDescription))")
                return [:]
            }
            AppLog.warning("Cloud check-in identity hint fetch recovered: \(AppLog.sanitize(error.localizedDescription))")
            return [:]
        }

        var hints: [String: LocalEmployeeIdentityHint] = [:]
        for record in records {
            guard let employeeId = record.string(CKSchema.CheckInField.employeeUserId),
                  let storeId = record.string(CKSchema.CheckInField.storeId),
                  managedStoreIds.contains(storeId) else {
                continue
            }

            let existing = hints[employeeId]
            let name = existing?.name ?? record.string(CKSchema.CheckInField.employeeName)
            let email = existing?.email ?? record.string(CKSchema.CheckInField.employeeEmail)
            let storeIds = Set([storeId]).union(existing?.storeIds ?? [])
            hints[employeeId] = LocalEmployeeIdentityHint(name: name, email: email, storeIds: storeIds)
        }
        return hints
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

        let existingProfile = try await resolveAnyProfile(userId: employeeId)
        let fallbackName = existingProfile?.name ?? "Employee"
        let fallbackEmail = existingProfile?.email
        let fallbackRole = existingProfile?.role ?? .employee

        var profile = try await profileStore.canonicalProfileEnsuringSeed(
            userId: employeeId,
            role: fallbackRole,
            provider: existingProfile?.provider ?? "apple",
            fallbackName: fallbackName,
            fallbackEmail: fallbackEmail
        )

        profile.assignedStoreIds = Array(Set(activeStoreIds)).sorted()
        profile.lastLoginAt = Date()

        _ = try await profileStore.upsertCanonicalProfile(profile, deletedAt: nil)
        await profileStore.upsertPublicProfileBestEffort(profile, deletedAt: nil)
    }

    private func recomputeAssignedStoresBestEffort(for employeeId: String, context: String) async {
        do {
            try await recomputeAssignedStores(for: employeeId)
        } catch {
            AppLog.warning(
                "Assigned store sync skipped context=\(context) user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))"
            )
        }
    }

    private func persistProfileBestEffort(_ profile: UserProfile, deletedAt: Date?, context: String) async {
        do {
            _ = try await profileStore.upsertCanonicalProfile(profile, deletedAt: deletedAt)
        } catch {
            AppLog.warning(
                "Canonical profile sync skipped context=\(context) user=\(AppLog.redactIdentifier(profile.id)): \(AppLog.sanitize(error.localizedDescription))"
            )
        }
        await profileStore.upsertPublicProfileBestEffort(profile, deletedAt: deletedAt)
    }

    private func resolveAnyProfile(userId: String) async throws -> UserProfile? {
        if let canonical = try await profileStore.fetchCanonicalProfile(userId: userId) {
            return canonical
        }
        return try await profileStore.fetchPublicProfile(userId: userId)
    }
}
