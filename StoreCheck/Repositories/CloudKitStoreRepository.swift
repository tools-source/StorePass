import CloudKit
import Foundation

@MainActor
final class CloudKitStoreRepository: StoreRepositoryProtocol {
    private let service: CloudKitService
    private let authService: AuthService
    private let userProfileStore: UserProfileStoreProtocol

    init(service: CloudKitService, authService: AuthService, userProfileStore: UserProfileStoreProtocol) {
        self.service = service
        self.authService = authService
        self.userProfileStore = userProfileStore
    }

    func fetchStores(ids: [String]?) async throws -> [Store] {
        try await service.ensureCloudKitAvailable()

        if let ids {
            if ids.isEmpty {
                if service.currentRole == .employee {
                    return try await fetchStores(ids: nil)
                }
                return []
            }
            var fetched: [Store] = []
            for id in ids {
                let recordID = CloudKitService.storeRecordID(storeId: id)
                do {
                    guard let record = try await service.fetchRecord(with: recordID),
                          let store = decodeStore(record: record),
                          store.isActive else {
                        continue
                    }
                    fetched.append(store)
                } catch {
                    guard isRecoverableManagerStoreError(error) else {
                        throw error
                    }
                    AppLog.warning("Store fetch by id skipped for id=\(id): \(AppLog.sanitize(error.localizedDescription))")
                }
            }
            return fetched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        guard let userId = service.currentUserId else {
            throw CloudKitClientError.signedOut
        }

        if service.currentRole == .manager {
            return try await fetchManagerStores(managerId: userId)
        }

        let memberships: [CKRecord]
        do {
            memberships = try await service.queryRecords(
                recordType: CKSchema.RecordType.storeMember,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.employeeUserId, userId),
                    NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.status, CKSchema.MemberStatus.active)
                ])
            )
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Employee membership store fetch recovered for user=\(AppLog.redactIdentifier(userId)): \(AppLog.sanitize(error.localizedDescription))")
            return []
        }

        let storeIds = memberships.compactMap { $0.string(CKSchema.StoreMemberField.storeId) }
        return try await fetchStores(ids: Array(Set(storeIds)))
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        try await service.ensureCloudKitAvailable()
        var privateStores: [Store] = []
        var privateQueryRecovered = false
        do {
            privateStores = try await queryManagerStores(managerId: managerId, in: service.privateDB)
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            privateQueryRecovered = true
            AppLog.warning("Private manager store fetch failed; falling back to profile-backed store IDs: \(AppLog.sanitize(error.localizedDescription))")
        }

        var publicStores: [Store] = []
        var publicQueryRecovered = false
        do {
            publicStores = try await queryManagerStores(managerId: managerId, in: service.publicDB)
            if !publicStores.isEmpty {
                await seedPrivateStoresBestEffort(publicStores)
            }
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            publicQueryRecovered = true
            AppLog.warning("Public manager store fetch failed; continuing with private canonical data: \(AppLog.sanitize(error.localizedDescription))")
        }

        let queriedStores = mergeStores(preferred: privateStores, fallback: publicStores)
        let idFallbackStores = await fetchManagerStoresViaProfileIDs(managerId: managerId)

        if queriedStores.isEmpty, !idFallbackStores.isEmpty {
            AppLog.info("Manager store fetch recovered via profile IDs for manager=\(AppLog.redactIdentifier(managerId)) count=\(idFallbackStores.count)")
            return idFallbackStores
        }

        if queriedStores.isEmpty, publicQueryRecovered || privateQueryRecovered {
            AppLog.warning("Manager store queries recovered with no results; returning empty store list for manager=\(AppLog.redactIdentifier(managerId))")
            return []
        }

        return mergeStores(preferred: queriedStores, fallback: idFallbackStores)
    }

    func upsertStore(_ store: Store) async throws {
        try await service.ensureCloudKitAvailable()

        guard let currentUserId = service.currentUserId else {
            throw CloudKitClientError.signedOut
        }

        try validateStore(name: store.name, address: store.address, latitude: store.latitude, longitude: store.longitude, radiusMeters: store.radiusMeters)
        let record = try await fetchManagerCanonicalStoreRecord(storeId: store.id, expectedManagerId: currentUserId)

        populateStoreRecord(
            record,
            store: store,
            joinCode: store.resolvedJoinCode,
            joinCodeHash: store.resolvedJoinCode.map { CloudKitService.stableHash(normalizeJoinCode($0)) },
            managerPublicRecordID: nil
        )

        let savedRecord = try await saveManagerStoreRecord(record, context: "upsertStore")
        await mirrorStoreRecordBestEffort(savedRecord, context: "upsertStore")
    }

    func deleteStore(id: String) async throws {
        try await service.ensureCloudKitAvailable()
        let currentUserId = try service.requireCurrentUserId()
        let privateStoreRecord = try await fetchStoreRecordIfOwnedByManager(
            storeId: id,
            expectedManagerId: currentUserId,
            in: service.privateDB
        )

        let publicStoreRecord: CKRecord?
        do {
            publicStoreRecord = try await fetchStoreRecordIfOwnedByManager(
                storeId: id,
                expectedManagerId: currentUserId,
                in: service.publicDB
            )
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Public store lookup skipped during deleteStore for store=\(id): \(AppLog.sanitize(error.localizedDescription))")
            publicStoreRecord = nil
        }

        guard privateStoreRecord != nil || publicStoreRecord != nil else {
            throw CloudKitClientError.missingRecord("Store not found.")
        }

        var publicRecordIDsToDelete: [CKRecord.ID] = []
        if let publicStoreRecord {
            publicRecordIDsToDelete.append(publicStoreRecord.recordID)
        }
        var employeeIds = Set<String>()

        do {
            let memberships = try await service.queryRecords(
                recordType: CKSchema.RecordType.storeMember,
                predicate: NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.storeId, id)
            )
            for membership in memberships {
                if let employeeId = membership.string(CKSchema.StoreMemberField.employeeUserId) {
                    employeeIds.insert(employeeId)
                }
            }
            publicRecordIDsToDelete.append(contentsOf: memberships.map(\.recordID))
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Membership lookup skipped during deleteStore: \(AppLog.sanitize(error.localizedDescription))")
        }

        do {
            let checkIns = try await service.queryRecords(
                recordType: CKSchema.RecordType.checkInSession,
                predicate: NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, id)
            )
            publicRecordIDsToDelete.append(contentsOf: checkIns.map(\.recordID))
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Check-in lookup skipped during deleteStore: \(AppLog.sanitize(error.localizedDescription))")
        }

        let uniquePublicRecordIDs = Array(Set(publicRecordIDsToDelete.map(\.recordName))).map { CKRecord.ID(recordName: $0) }
        if !uniquePublicRecordIDs.isEmpty {
            do {
                _ = try await service.modify(
                    recordsToSave: [],
                    recordIDsToDelete: uniquePublicRecordIDs,
                    atomic: false,
                    in: service.publicDB
                )
            } catch {
                guard isRecoverableManagerStoreError(error) else {
                    throw error
                }
                AppLog.warning("Public cleanup skipped during deleteStore for store=\(id): \(AppLog.sanitize(error.localizedDescription))")
            }
        }

        if let privateStoreRecord {
            try await service.deleteRecord(with: privateStoreRecord.recordID, in: service.privateDB)
        } else {
            AppLog.warning("Private store record missing during deleteStore; completed using public-only cleanup for store=\(id)")
        }

        await syncManagerOwnedStoreIdsBestEffort(managerId: currentUserId, storeId: id, isAdding: false, context: "deleteStore")

        for employeeId in employeeIds {
            await recomputeAssignedStoresBestEffort(for: employeeId, context: "deleteStore")
        }
    }

    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async throws -> StoreCreationResult {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        try validateStore(name: name, address: address, latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)

        if let signedInUser = authService.currentUser, signedInUser.id == currentUserId {
            guard signedInUser.role == .manager else {
                throw CloudKitClientError.invalidData("Manager access is required to create stores.")
            }
            guard signedInUser.isActive else {
                throw CloudKitClientError.invalidData("Your manager account is inactive.")
            }
        } else if service.currentRole != .manager {
            throw CloudKitClientError.invalidData("Manager access is required to create stores.")
        } else {
            AppLog.warning("Manager profile not available in session during createStore; proceeding with current manager identity")
        }

        let storeId = UUID().uuidString
        let joinCode = Self.generateJoinCode()
        let joinCodeHash = CloudKitService.stableHash(normalizeJoinCode(joinCode))
        let now = Date()
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

        let record = CKRecord(recordType: CKSchema.RecordType.store, recordID: CloudKitService.storeRecordID(storeId: storeId))
        populateStoreRecord(
            record,
            store: store,
            joinCode: joinCode,
            joinCodeHash: joinCodeHash,
            managerPublicRecordID: nil
        )

        let savedRecord = try await saveManagerStoreRecord(record, context: "createStore")
        await mirrorStoreRecordBestEffort(savedRecord, context: "createStore")
        await syncManagerOwnedStoreIdsBestEffort(managerId: currentUserId, storeId: store.id, isAdding: true, context: "createStore")

        return StoreCreationResult(store: store, joinCode: joinCode)
    }

    func rotateStoreCode(storeId: String) async throws -> String {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        let record = try await fetchManagerCanonicalStoreRecord(storeId: storeId, expectedManagerId: currentUserId)

        let newCode = Self.generateJoinCode()
        record[CKSchema.StoreField.joinCode] = newCode as CKRecordValue
        record[CKSchema.StoreField.joinCodeHash] = CloudKitService.stableHash(normalizeJoinCode(newCode)) as CKRecordValue
        record[CKSchema.StoreField.joinCodeLast4] = String(newCode.suffix(4)) as CKRecordValue
        record[CKSchema.StoreField.updatedAt] = Date() as CKRecordValue

        let savedRecord = try await saveManagerStoreRecord(record, context: "rotateStoreCode")
        await mirrorStoreRecordBestEffort(savedRecord, context: "rotateStoreCode")
        return newCode
    }

    func getStoreJoinCode(storeId: String) async throws -> String {
        try await service.ensureCloudKitAvailable()

        let currentUserId = try service.requireCurrentUserId()
        let record = try await fetchManagerCanonicalStoreRecord(storeId: storeId, expectedManagerId: currentUserId)

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
        guard let userProfile = try await currentUserProfile(userId: currentUserId) else {
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

        if let publicUserRecordID = await userProfileStore.resolvePublicUserRecordID(userId: currentUserId) {
            membership[CKSchema.StoreMemberField.employeeUserRef] = CKRecord.Reference(recordID: publicUserRecordID, action: .none)
        } else {
            membership[CKSchema.StoreMemberField.employeeUserRef] = nil
        }

        membership[CKSchema.StoreMemberField.employeeName] = userProfile.name as CKRecordValue
        if let email = userProfile.email, !email.isEmpty {
            membership[CKSchema.StoreMemberField.employeeEmail] = email as CKRecordValue
        }
        membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.active as CKRecordValue
        if membership.date(CKSchema.StoreMemberField.joinedAt) == nil {
            membership[CKSchema.StoreMemberField.joinedAt] = Date() as CKRecordValue
        }
        membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue

        let previousAssignedStoreIds = Set(userProfile.assignedStoreIds)
        var updatedProfile = userProfile
        updatedProfile.assignedStoreIds = Array(previousAssignedStoreIds.union([store.id])).sorted()
        updatedProfile.lastLoginAt = Date()

        _ = try await service.save(record: membership)
        await persistProfileBestEffort(updatedProfile, deletedAt: nil, context: "joinStoreByCode")

        return JoinStoreResult(
            storeId: store.id,
            storeName: store.name,
            alreadyJoined: alreadyJoined,
            assignedStoreIds: updatedProfile.assignedStoreIds
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
        _ = try await service.save(record: membership)

        await recomputeAssignedStoresBestEffort(for: currentUserId, context: "leaveStore")
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

        var profile = try await userProfileStore.canonicalProfileEnsuringSeed(
            userId: employeeId,
            role: fallbackRole,
            provider: existingProfile?.provider ?? "apple",
            fallbackName: fallbackName,
            fallbackEmail: fallbackEmail
        )

        profile.assignedStoreIds = Array(Set(activeStoreIds)).sorted()
        profile.lastLoginAt = Date()

        _ = try await userProfileStore.upsertCanonicalProfile(profile, deletedAt: nil)
        await userProfileStore.upsertPublicProfileBestEffort(profile, deletedAt: nil)
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
            _ = try await userProfileStore.upsertCanonicalProfile(profile, deletedAt: deletedAt)
        } catch {
            AppLog.warning(
                "Canonical profile sync skipped context=\(context) user=\(AppLog.redactIdentifier(profile.id)): \(AppLog.sanitize(error.localizedDescription))"
            )
        }
        await userProfileStore.upsertPublicProfileBestEffort(profile, deletedAt: deletedAt)
    }

    private func currentUserProfile(userId: String) async throws -> UserProfile? {
        if let currentUser = authService.currentUser, currentUser.id == userId {
            return currentUser
        }
        return try await resolveAnyProfile(userId: userId)
    }

    private func resolveAnyProfile(userId: String) async throws -> UserProfile? {
        if let canonical = try await userProfileStore.fetchCanonicalProfile(userId: userId) {
            return canonical
        }
        return try await userProfileStore.fetchPublicProfile(userId: userId)
    }

    private func fetchManagerStoresViaProfileIDs(managerId: String) async -> [Store] {
        do {
            guard let profile = try await currentUserProfile(userId: managerId) else {
                return []
            }

            let fallbackStoreIds = Array(Set(profile.assignedStoreIds)).sorted()
            guard !fallbackStoreIds.isEmpty else {
                return []
            }

            var resolvedStores: [Store] = []
            for storeId in fallbackStoreIds {
                if let store = await fetchManagerStoreByID(storeId: storeId, managerId: managerId) {
                    resolvedStores.append(store)
                }
            }

            return resolvedStores.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            AppLog.warning("Manager profile ID fallback failed for manager=\(AppLog.redactIdentifier(managerId)): \(AppLog.sanitize(error.localizedDescription))")
            return []
        }
    }

    private func fetchManagerStoreByID(storeId: String, managerId: String) async -> Store? {
        let recordID = CloudKitService.storeRecordID(storeId: storeId)

        do {
            if let privateRecord = try await service.fetchRecord(with: recordID, in: service.privateDB),
               let store = decodeStore(record: privateRecord),
               store.isActive,
               store.managerId == managerId {
                return store
            }
        } catch {
            if !isRecoverableManagerStoreError(error) {
                AppLog.warning("Private manager store ID fetch failed store=\(storeId): \(AppLog.sanitize(error.localizedDescription))")
            }
        }

        do {
            if let publicRecord = try await service.fetchRecord(with: recordID),
               let store = decodeStore(record: publicRecord),
               store.isActive,
               store.managerId == managerId {
                return store
            }
        } catch {
            if !isRecoverableManagerStoreError(error) {
                AppLog.warning("Public manager store ID fetch failed store=\(storeId): \(AppLog.sanitize(error.localizedDescription))")
            }
        }

        return nil
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

    private func fetchManagerCanonicalStoreRecord(storeId: String, expectedManagerId: String) async throws -> CKRecord {
        let recordID = CloudKitService.storeRecordID(storeId: storeId)

        if let privateRecord = try await service.fetchRecord(with: recordID, in: service.privateDB) {
            guard privateRecord.string(CKSchema.StoreField.managerUserId) == expectedManagerId else {
                throw CloudKitClientError.unauthorized
            }
            return privateRecord
        }

        do {
            if let publicRecord = try await service.fetchRecord(with: recordID) {
                guard publicRecord.string(CKSchema.StoreField.managerUserId) == expectedManagerId else {
                    throw CloudKitClientError.unauthorized
                }

                let privateRecord = cloneStoreRecord(publicRecord, includeManagerReference: false, managerPublicRecordID: nil)
                do {
                    _ = try await service.save(record: privateRecord, in: service.privateDB)
                } catch {
                    guard isRecoverableManagerStoreError(error) else {
                        throw error
                    }
                    AppLog.warning("Private canonical store seed failed for store=\(storeId); using in-memory private clone: \(AppLog.sanitize(error.localizedDescription))")
                }
                return privateRecord
            }
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Public canonical store fetch failed for store=\(storeId): \(AppLog.sanitize(error.localizedDescription))")
        }

        throw CloudKitClientError.missingRecord("Store not found.")
    }

    private func fetchStoreRecordIfOwnedByManager(
        storeId: String,
        expectedManagerId: String,
        in database: CKDatabase
    ) async throws -> CKRecord? {
        let recordID = CloudKitService.storeRecordID(storeId: storeId)
        guard let record = try await service.fetchRecord(with: recordID, in: database) else {
            return nil
        }
        guard record.string(CKSchema.StoreField.managerUserId) == expectedManagerId else {
            throw CloudKitClientError.unauthorized
        }
        return record
    }

    private func populateStoreRecord(
        _ record: CKRecord,
        store: Store,
        joinCode: String?,
        joinCodeHash: String?,
        managerPublicRecordID: CKRecord.ID?
    ) {
        record[CKSchema.StoreField.storeId] = store.id as CKRecordValue
        if let managerId = store.managerId {
            record[CKSchema.StoreField.managerUserId] = managerId as CKRecordValue
        }

        if let managerPublicRecordID {
            record[CKSchema.StoreField.managerUserRef] = CKRecord.Reference(recordID: managerPublicRecordID, action: .none)
        } else {
            record[CKSchema.StoreField.managerUserRef] = nil
        }

        record[CKSchema.StoreField.name] = store.name.trimmingCharacters(in: .whitespacesAndNewlines) as CKRecordValue
        record[CKSchema.StoreField.address] = store.address.trimmingCharacters(in: .whitespacesAndNewlines) as CKRecordValue
        record[CKSchema.StoreField.latitude] = NSNumber(value: store.latitude)
        record[CKSchema.StoreField.longitude] = NSNumber(value: store.longitude)
        record[CKSchema.StoreField.radiusMeters] = NSNumber(value: store.radiusMeters)
        record[CKSchema.StoreField.isActive] = NSNumber(value: store.isActive)
        if let joinCode, !joinCode.isEmpty {
            record[CKSchema.StoreField.joinCode] = joinCode as CKRecordValue
            record[CKSchema.StoreField.joinCodeLast4] = String(joinCode.suffix(4)) as CKRecordValue
        }
        if let joinCodeHash, !joinCodeHash.isEmpty {
            record[CKSchema.StoreField.joinCodeHash] = joinCodeHash as CKRecordValue
        }
        if let createdAt = store.createdAt ?? record.date(CKSchema.StoreField.createdAt) {
            record[CKSchema.StoreField.createdAt] = createdAt as CKRecordValue
        }
        record[CKSchema.StoreField.updatedAt] = (store.updatedAt ?? Date()) as CKRecordValue
        if store.isActive {
            record[CKSchema.StoreField.deletedAt] = nil
        }
    }

    private func cloneStoreRecord(
        _ record: CKRecord,
        includeManagerReference: Bool,
        managerPublicRecordID: CKRecord.ID?
    ) -> CKRecord {
        let copy = CKRecord(recordType: CKSchema.RecordType.store, recordID: record.recordID)
        for key in [
            CKSchema.StoreField.storeId,
            CKSchema.StoreField.managerUserId,
            CKSchema.StoreField.name,
            CKSchema.StoreField.address,
            CKSchema.StoreField.latitude,
            CKSchema.StoreField.longitude,
            CKSchema.StoreField.radiusMeters,
            CKSchema.StoreField.joinCodeHash,
            CKSchema.StoreField.joinCode,
            CKSchema.StoreField.joinCodeLast4,
            CKSchema.StoreField.isActive,
            CKSchema.StoreField.createdAt,
            CKSchema.StoreField.updatedAt,
            CKSchema.StoreField.deletedAt
        ] {
            copy[key] = record[key]
        }
        if includeManagerReference, let managerPublicRecordID {
            copy[CKSchema.StoreField.managerUserRef] = CKRecord.Reference(recordID: managerPublicRecordID, action: .none)
        } else {
            copy[CKSchema.StoreField.managerUserRef] = nil
        }
        return copy
    }

    private func seedPrivateStoresBestEffort(_ stores: [Store]) async {
        guard !stores.isEmpty else { return }

        for store in stores {
            let record = CKRecord(recordType: CKSchema.RecordType.store, recordID: CloudKitService.storeRecordID(storeId: store.id))
            populateStoreRecord(
                record,
                store: store,
                joinCode: store.resolvedJoinCode,
                joinCodeHash: store.resolvedJoinCode.map { CloudKitService.stableHash(normalizeJoinCode($0)) },
                managerPublicRecordID: nil
            )

            do {
                _ = try await service.save(record: record, in: service.privateDB)
            } catch {
                AppLog.warning("Private manager store seed skipped for store=\(store.id): \(AppLog.sanitize(error.localizedDescription))")
            }
        }
    }

    private func saveManagerStoreRecord(_ record: CKRecord, context: String) async throws -> CKRecord {
        do {
            return try await service.save(record: record, in: service.privateDB)
        } catch let privateError {
            guard isRecoverableManagerStoreError(privateError) else {
                throw privateError
            }

            AppLog.warning("Manager store private save failed context=\(context): \(AppLog.sanitize(privateError.localizedDescription))")

            do {
                let (savedRecords, _) = try await service.modify(
                    recordsToSave: [record],
                    savePolicy: .allKeys,
                    atomic: true,
                    in: service.privateDB
                )
                if let saved = savedRecords.first {
                    AppLog.info("Manager store private modify fallback succeeded context=\(context) store=\(saved.recordID.recordName)")
                    return saved
                }
            } catch let privateModifyError {
                guard isRecoverableManagerStoreError(privateModifyError) else {
                    throw privateModifyError
                }
                AppLog.warning(
                    "Manager store private modify fallback failed context=\(context): \(AppLog.sanitize(privateModifyError.localizedDescription))"
                )
            }

            let managerPublicRecordID: CKRecord.ID?
            if let managerUserId = record.string(CKSchema.StoreField.managerUserId) {
                managerPublicRecordID = await userProfileStore.resolvePublicUserRecordID(userId: managerUserId)
            } else {
                managerPublicRecordID = nil
            }

            let publicRecord = cloneStoreRecord(
                record,
                includeManagerReference: managerPublicRecordID != nil,
                managerPublicRecordID: managerPublicRecordID
            )

            do {
                let saved = try await service.save(record: publicRecord, in: service.publicDB)
                AppLog.warning("Manager store persisted in public scope only context=\(context) store=\(saved.recordID.recordName)")
                return saved
            } catch let publicError {
                guard isRecoverableManagerStoreError(publicError) else {
                    throw publicError
                }
                AppLog.warning("Manager store public fallback failed context=\(context): \(AppLog.sanitize(publicError.localizedDescription))")
                throw privateError
            }
        }
    }

    private func mirrorStoreRecordBestEffort(_ record: CKRecord, context: String) async {
        let managerPublicRecordID: CKRecord.ID?
        if let managerUserId = record.string(CKSchema.StoreField.managerUserId) {
            managerPublicRecordID = await userProfileStore.resolvePublicUserRecordID(userId: managerUserId)
        } else {
            managerPublicRecordID = nil
        }

        let publicRecord = cloneStoreRecord(
            record,
            includeManagerReference: managerPublicRecordID != nil,
            managerPublicRecordID: managerPublicRecordID
        )
        do {
            _ = try await service.save(record: publicRecord, in: service.publicDB)
        } catch {
            AppLog.warning("Public store mirror skipped context=\(context) store=\(record.recordID.recordName): \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func isRecoverableManagerStoreError(_ error: Error) -> Bool {
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

    private func syncManagerOwnedStoreIdsBestEffort(managerId: String, storeId: String, isAdding: Bool, context: String) async {
        do {
            guard var profile = try await currentUserProfile(userId: managerId) else {
                return
            }

            var ownedStoreIds = Set(profile.assignedStoreIds)
            if isAdding {
                ownedStoreIds.insert(storeId)
            } else {
                ownedStoreIds.remove(storeId)
            }

            profile.assignedStoreIds = ownedStoreIds.sorted()
            profile.lastLoginAt = Date()

            try await persistCanonicalProfile(profile, deletedAt: nil, context: context)
        } catch {
            AppLog.warning("Manager owned store sync skipped context=\(context) manager=\(AppLog.redactIdentifier(managerId)): \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func persistCanonicalProfile(_ profile: UserProfile, deletedAt: Date?, context: String) async throws {
        let savedProfile = try await userProfileStore.upsertCanonicalProfile(profile, deletedAt: deletedAt)
        if authService.currentUser?.id == savedProfile.id {
            authService.setCurrentUser(savedProfile)
        }
        await userProfileStore.upsertPublicProfileBestEffort(savedProfile, deletedAt: deletedAt)
        AppLog.info("Canonical profile persisted context=\(context) user=\(AppLog.redactIdentifier(savedProfile.id))")
    }

    private static func generateJoinCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}

private extension Optional where Wrapped == String {
    func flatMapAsync<T>(_ transform: (String) async -> T?) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
