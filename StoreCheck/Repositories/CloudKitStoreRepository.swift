import CloudKit
import Foundation

@MainActor
final class CloudKitStoreRepository: StoreRepositoryProtocol {
    private let service: CloudKitService
    private let authService: AuthService
    private let userProfileStore: UserProfileStoreProtocol
    private static let localFallbackStoresKey = "storecheck.local_manager_stores.v1"
    private static let localFallbackEmployeeLinksKey = "storecheck.local_employee_store_links.v1"
    private static let localBroadcastMessagesKey = "storecheck.local_broadcast_messages.v1"

    init(service: CloudKitService, authService: AuthService, userProfileStore: UserProfileStoreProtocol) {
        self.service = service
        self.authService = authService
        self.userProfileStore = userProfileStore
    }

    func fetchStores(ids: [String]?) async throws -> [Store] {
        if service.isCloudKitIdentityMismatchDetected {
            if let ids {
                if ids.isEmpty {
                    return []
                }
                if service.currentRole == .manager, let managerId = service.currentUserId {
                    return localFallbackStores(managerId: managerId).filter { ids.contains($0.id) }
                }
                return localFallbackStores(storeIDs: Set(ids))
            }

            guard let userId = service.currentUserId else {
                throw CloudKitClientError.signedOut
            }

            if service.currentRole == .manager {
                return localFallbackStores(managerId: userId)
            }

            let localLinkedStoreIDs = localFallbackStoreIDs(forEmployee: userId)
            return localFallbackStores(storeIDs: Set(localLinkedStoreIDs))
        }

        try await service.ensureCloudKitAvailable()

        if let ids {
            if ids.isEmpty {
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
            let localStores: [Store]
            if service.currentRole == .manager, let managerId = service.currentUserId {
                localStores = localFallbackStores(managerId: managerId).filter { ids.contains($0.id) }
            } else {
                localStores = localFallbackStores(storeIDs: Set(ids))
            }
            return mergeStores(preferred: fetched, fallback: localStores)
        }

        guard let userId = service.currentUserId else {
            throw CloudKitClientError.signedOut
        }

        if service.currentRole == .manager {
            return try await fetchManagerStores(managerId: userId)
        }

        let localLinkedStoreIDs = localFallbackStoreIDs(forEmployee: userId)
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
            return localFallbackStores(storeIDs: Set(localLinkedStoreIDs))
        }

        let cloudStoreIDs = memberships.compactMap { $0.string(CKSchema.StoreMemberField.storeId) }
        let allStoreIDs = Array(Set(cloudStoreIDs).union(localLinkedStoreIDs))
        return try await fetchStores(ids: allStoreIDs)
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        if service.isCloudKitIdentityMismatchDetected {
            let localStores = localFallbackStores(managerId: managerId)
            AppLog.warning("Manager store fetch using local-only mode manager=\(AppLog.redactIdentifier(managerId)) count=\(localStores.count)")
            return localStores
        }

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
        let localStores = localFallbackStores(managerId: managerId)
        if !localStores.isEmpty {
            AppLog.warning("Using local store fallback for manager=\(AppLog.redactIdentifier(managerId)) count=\(localStores.count)")
        }

        if queriedStores.isEmpty, !idFallbackStores.isEmpty {
            AppLog.info("Manager store fetch recovered via profile IDs for manager=\(AppLog.redactIdentifier(managerId)) count=\(idFallbackStores.count)")
            return mergeStores(preferred: idFallbackStores, fallback: localStores)
        }

        if queriedStores.isEmpty, publicQueryRecovered || privateQueryRecovered {
            AppLog.warning("Manager store queries recovered with no cloud results; returning local fallback stores for manager=\(AppLog.redactIdentifier(managerId)) count=\(localStores.count)")
            return localStores
        }

        let mergedCloud = mergeStores(preferred: queriedStores, fallback: idFallbackStores)
        return mergeStores(preferred: mergedCloud, fallback: localStores)
    }

    func upsertStore(_ store: Store) async throws {
        guard let currentUserId = service.currentUserId else {
            throw CloudKitClientError.signedOut
        }

        try validateStore(name: store.name, address: store.address, latitude: store.latitude, longitude: store.longitude, radiusMeters: store.radiusMeters)

        if service.isCloudKitIdentityMismatchDetected {
            persistLocalFallbackStore(store, managerId: currentUserId)
            return
        }

        try await service.ensureCloudKitAvailable()
        if localFallbackStore(storeId: store.id, managerId: currentUserId) != nil {
            persistLocalFallbackStore(store, managerId: currentUserId)
            return
        }

        do {
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
        } catch {
            guard shouldUseLocalStoreFallback(for: error) else {
                throw error
            }
            AppLog.warning("Store upsert fell back to local persistence store=\(store.id): \(AppLog.sanitize(error.localizedDescription))")
            persistLocalFallbackStore(store, managerId: currentUserId)
        }
    }

    func deleteStore(id: String) async throws {
        let currentUserId = try service.requireCurrentUserId()

        if service.isCloudKitIdentityMismatchDetected {
            deleteLocalFallbackStore(storeId: id, managerId: currentUserId)
            return
        }

        try await service.ensureCloudKitAvailable()
        if localFallbackStore(storeId: id, managerId: currentUserId) != nil {
            deleteLocalFallbackStore(storeId: id, managerId: currentUserId)
            return
        }

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

        if service.isCloudKitIdentityMismatchDetected {
            persistLocalFallbackStore(store, managerId: currentUserId)
            return StoreCreationResult(store: store, joinCode: joinCode)
        }

        try await service.ensureCloudKitAvailable()

        let record = CKRecord(recordType: CKSchema.RecordType.store, recordID: CloudKitService.storeRecordID(storeId: storeId))
        populateStoreRecord(
            record,
            store: store,
            joinCode: joinCode,
            joinCodeHash: joinCodeHash,
            managerPublicRecordID: nil
        )

        do {
            let savedRecord = try await saveManagerStoreRecord(record, context: "createStore")
            await mirrorStoreRecordBestEffort(savedRecord, context: "createStore")
            await syncManagerOwnedStoreIdsBestEffort(managerId: currentUserId, storeId: store.id, isAdding: true, context: "createStore")
            return StoreCreationResult(store: store, joinCode: joinCode)
        } catch {
            guard shouldUseLocalStoreFallback(for: error) else {
                throw error
            }
            AppLog.warning("Store create fell back to local persistence store=\(store.id): \(AppLog.sanitize(error.localizedDescription))")
            persistLocalFallbackStore(store, managerId: currentUserId)
            return StoreCreationResult(store: store, joinCode: joinCode)
        }
    }

    func rotateStoreCode(storeId: String) async throws -> String {
        let currentUserId = try service.requireCurrentUserId()
        if localFallbackStore(storeId: storeId, managerId: currentUserId) != nil {
            return try rotateLocalFallbackJoinCode(storeId: storeId, managerId: currentUserId)
        }

        if service.isCloudKitIdentityMismatchDetected {
            throw CloudKitClientError.missingRecord("Store code not found.")
        }

        try await service.ensureCloudKitAvailable()

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
        let currentUserId = try service.requireCurrentUserId()
        if let localStore = localFallbackStore(storeId: storeId, managerId: currentUserId) {
            if let localCode = localStore.resolvedJoinCode, !localCode.isEmpty {
                return localCode
            }
            return try rotateLocalFallbackJoinCode(storeId: storeId, managerId: currentUserId)
        }

        if service.isCloudKitIdentityMismatchDetected {
            throw CloudKitClientError.missingRecord("Store code not found.")
        }

        try await service.ensureCloudKitAvailable()

        let record = try await fetchManagerCanonicalStoreRecord(storeId: storeId, expectedManagerId: currentUserId)

        if let existing = record.string(CKSchema.StoreField.joinCode), !existing.isEmpty {
            return existing
        }

        return try await rotateStoreCode(storeId: storeId)
    }

    func joinStoreByCode(code: String) async throws -> JoinStoreResult {
        let normalizedCode = normalizeJoinCode(code)
        guard normalizedCode.count >= 6 else {
            throw CloudKitClientError.invalidData("Enter a valid join code.")
        }

        let currentUserId = try service.requireCurrentUserId()
        let codeHash = CloudKitService.stableHash(normalizedCode)

        if service.isCloudKitIdentityMismatchDetected {
            guard let localProfile = authService.currentUser, localProfile.id == currentUserId else {
                throw CloudKitClientError.missingRecord("Employee profile unavailable in local mode. Sign in again.")
            }

            guard localProfile.role == .employee else {
                throw CloudKitClientError.invalidData("Only employees can join stores by code.")
            }

            guard localProfile.isActive else {
                throw CloudKitClientError.invalidData("Your account is inactive. Contact your manager.")
            }

            return try joinLocalFallbackStoreByCode(
                normalizedCode: normalizedCode,
                codeHash: codeHash,
                currentUserId: currentUserId,
                employeeName: localProfile.name,
                employeeEmail: localProfile.email
            )
        }

        guard let userProfile = try await currentUserProfile(userId: currentUserId) else {
            throw CloudKitClientError.missingRecord("Your profile is missing. Sign in again.")
        }

        guard userProfile.role == .employee else {
            throw CloudKitClientError.invalidData("Only employees can join stores by code.")
        }

        guard userProfile.isActive else {
            throw CloudKitClientError.invalidData("Your account is inactive. Contact your manager.")
        }

        try await service.ensureCloudKitAvailable()

        do {
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
            setLocalFallbackStoreMembership(
                employeeId: currentUserId,
                storeId: store.id,
                isActive: true,
                employeeName: userProfile.name,
                employeeEmail: userProfile.email
            )
            await persistProfileBestEffort(updatedProfile, deletedAt: nil, context: "joinStoreByCode")

            return JoinStoreResult(
                storeId: store.id,
                storeName: store.name,
                alreadyJoined: alreadyJoined,
                assignedStoreIds: Array(Set(updatedProfile.assignedStoreIds).union(localFallbackStoreIDs(forEmployee: currentUserId))).sorted()
            )
        } catch {
            guard shouldUseLocalStoreFallback(for: error) else {
                throw error
            }
            AppLog.warning("Join store fell back to local lookup: \(AppLog.sanitize(error.localizedDescription))")
            return try joinLocalFallbackStoreByCode(
                normalizedCode: normalizedCode,
                codeHash: codeHash,
                currentUserId: currentUserId,
                employeeName: userProfile.name,
                employeeEmail: userProfile.email
            )
        }
    }

    func leaveStore(storeId: String) async throws {
        let currentUserId = try service.requireCurrentUserId()
        setLocalFallbackStoreMembership(employeeId: currentUserId, storeId: storeId, isActive: false, employeeName: nil, employeeEmail: nil)

        if service.isCloudKitIdentityMismatchDetected {
            return
        }

        try await service.ensureCloudKitAvailable()

        do {
            let membershipRecordID = CloudKitService.membershipRecordID(storeId: storeId, employeeId: currentUserId)
            guard let membership = try await service.fetchRecord(with: membershipRecordID) else {
                return
            }

            membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.removed as CKRecordValue
            membership[CKSchema.StoreMemberField.updatedAt] = Date() as CKRecordValue
            _ = try await service.save(record: membership)

            await recomputeAssignedStoresBestEffort(for: currentUserId, context: "leaveStore")
        } catch {
            guard shouldUseLocalStoreFallback(for: error) else {
                throw error
            }
            AppLog.warning("Leave store fell back to local membership update store=\(storeId): \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    func setStoreQRCheckInMode(storeId: String, isEnabled: Bool) async throws -> Store {
        let currentUserId = try service.requireCurrentUserId()

        if var localStore = localFallbackStore(storeId: storeId, managerId: currentUserId) {
            localStore.qrCheckInEnabled = isEnabled
            if isEnabled, (localStore.qrCodeToken?.isEmpty ?? true) {
                localStore.qrCodeToken = Self.generateQRCodeToken()
            }
            localStore.updatedAt = Date()
            persistLocalFallbackStore(localStore, managerId: currentUserId)
            return localStore
        }

        if service.isCloudKitIdentityMismatchDetected {
            throw CloudKitClientError.missingRecord("Store not found.")
        }

        try await service.ensureCloudKitAvailable()
        let record = try await fetchManagerCanonicalStoreRecord(storeId: storeId, expectedManagerId: currentUserId)
        record[CKSchema.StoreField.qrCheckInEnabled] = NSNumber(value: isEnabled)
        if isEnabled {
            let existingToken = record.string(CKSchema.StoreField.qrCodeToken)
            if existingToken?.isEmpty ?? true {
                record[CKSchema.StoreField.qrCodeToken] = Self.generateQRCodeToken() as CKRecordValue
            }
        }
        record[CKSchema.StoreField.updatedAt] = Date() as CKRecordValue

        let saved = try await saveManagerStoreRecord(record, context: "setStoreQRCheckInMode")
        await mirrorStoreRecordBestEffort(saved, context: "setStoreQRCheckInMode")
        guard let decoded = decodeStore(record: saved) else {
            throw CloudKitClientError.invalidData("Store update failed.")
        }
        return decoded
    }

    func rotateStoreQRCode(storeId: String) async throws -> String {
        let currentUserId = try service.requireCurrentUserId()

        if var localStore = localFallbackStore(storeId: storeId, managerId: currentUserId) {
            let token = Self.generateQRCodeToken()
            localStore.qrCodeToken = token
            localStore.qrCheckInEnabled = true
            localStore.updatedAt = Date()
            persistLocalFallbackStore(localStore, managerId: currentUserId)
            return token
        }

        if service.isCloudKitIdentityMismatchDetected {
            throw CloudKitClientError.missingRecord("Store not found.")
        }

        try await service.ensureCloudKitAvailable()
        let record = try await fetchManagerCanonicalStoreRecord(storeId: storeId, expectedManagerId: currentUserId)
        let token = Self.generateQRCodeToken()
        record[CKSchema.StoreField.qrCodeToken] = token as CKRecordValue
        record[CKSchema.StoreField.qrCheckInEnabled] = NSNumber(value: true)
        record[CKSchema.StoreField.updatedAt] = Date() as CKRecordValue

        let saved = try await saveManagerStoreRecord(record, context: "rotateStoreQRCode")
        await mirrorStoreRecordBestEffort(saved, context: "rotateStoreQRCode")
        return token
    }

    func sendBroadcastMessage(storeId: String, message: String) async throws {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw CloudKitClientError.invalidData("Message cannot be empty.")
        }
        guard trimmedMessage.count <= 500 else {
            throw CloudKitClientError.invalidData("Message is too long.")
        }

        let managerId = try service.requireCurrentUserId()
        let managerName = authService.currentUser?.name ?? "Manager"
        let now = Date()

        let broadcast = BroadcastMessage(
            id: UUID().uuidString,
            storeId: storeId,
            storeName: (try await fetchStores(ids: [storeId]).first?.name) ?? "Store",
            managerUserId: managerId,
            managerName: managerName,
            message: trimmedMessage,
            createdAt: now
        )

        persistLocalBroadcastMessage(broadcast)

        if service.isCloudKitIdentityMismatchDetected {
            return
        }

        try await service.ensureCloudKitAvailable()

        do {
            _ = try await fetchManagerCanonicalStoreRecord(storeId: storeId, expectedManagerId: managerId)
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
        }

        let recordID = CKRecord.ID(recordName: "broadcast_\(CloudKitService.stableHash("\(storeId)|\(broadcast.id)"))")
        let record = CKRecord(recordType: CKSchema.RecordType.broadcastMessage, recordID: recordID)
        record[CKSchema.BroadcastField.messageId] = broadcast.id as CKRecordValue
        record[CKSchema.BroadcastField.storeId] = broadcast.storeId as CKRecordValue
        record[CKSchema.BroadcastField.storeRef] = CKRecord.Reference(recordID: CloudKitService.storeRecordID(storeId: storeId), action: .none)
        record[CKSchema.BroadcastField.storeName] = broadcast.storeName as CKRecordValue
        record[CKSchema.BroadcastField.managerUserId] = managerId as CKRecordValue
        record[CKSchema.BroadcastField.managerName] = managerName as CKRecordValue
        record[CKSchema.BroadcastField.message] = trimmedMessage as CKRecordValue
        record[CKSchema.BroadcastField.createdAt] = now as CKRecordValue

        do {
            _ = try await service.save(record: record, in: service.publicDB)
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            AppLog.warning("Broadcast cloud save failed; local fallback kept: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    func fetchBroadcastMessages(storeId: String, limit: Int) async throws -> [BroadcastMessage] {
        let currentUserId = try service.requireCurrentUserId()
        let localMessages = localBroadcastMessages(for: storeId)

        if service.isCloudKitIdentityMismatchDetected {
            return Array(localMessages.prefix(limit))
        }

        try await service.ensureCloudKitAvailable()

        if service.currentRole == .manager {
            do {
                _ = try await fetchManagerCanonicalStoreRecord(storeId: storeId, expectedManagerId: currentUserId)
            } catch {
                guard isRecoverableManagerStoreError(error) else {
                    throw error
                }
            }
        } else {
            let membershipRecordID = CloudKitService.membershipRecordID(storeId: storeId, employeeId: currentUserId)
            do {
                guard let membership = try await service.fetchRecord(with: membershipRecordID),
                      membership.string(CKSchema.StoreMemberField.status) == CKSchema.MemberStatus.active else {
                    return []
                }
            } catch {
                guard isRecoverableManagerStoreError(error) else {
                    throw error
                }
            }
        }

        let records: [CKRecord]
        do {
            records = try await service.queryRecords(
                recordType: CKSchema.RecordType.broadcastMessage,
                predicate: NSPredicate(format: "%K == %@", CKSchema.BroadcastField.storeId, storeId),
                sortDescriptors: [NSSortDescriptor(key: CKSchema.BroadcastField.createdAt, ascending: false)],
                resultsLimit: max(limit, 1),
                in: service.publicDB
            )
        } catch {
            guard isRecoverableManagerStoreError(error) else {
                throw error
            }
            return Array(localMessages.prefix(limit))
        }

        let cloudMessages = records.compactMap(decodeBroadcastMessage(record:))
        let merged = mergeBroadcastMessages(preferred: cloudMessages, fallback: localMessages)
        return Array(merged.prefix(limit))
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
        record[CKSchema.StoreField.timeZoneIdentifier] = store.timeZoneIdentifier as CKRecordValue
        record[CKSchema.StoreField.qrCheckInEnabled] = NSNumber(value: store.qrCheckInEnabled)
        if let qrCodeToken = store.qrCodeToken, !qrCodeToken.isEmpty {
            record[CKSchema.StoreField.qrCodeToken] = qrCodeToken as CKRecordValue
        } else {
            record[CKSchema.StoreField.qrCodeToken] = nil
        }
        record[CKSchema.StoreField.longShiftWarningHours] = NSNumber(value: max(store.longShiftWarningHours, 1))
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
            CKSchema.StoreField.timeZoneIdentifier,
            CKSchema.StoreField.qrCheckInEnabled,
            CKSchema.StoreField.qrCodeToken,
            CKSchema.StoreField.longShiftWarningHours,
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

    private struct LocalBroadcastPayload: Codable {
        var messagesByStoreId: [String: [BroadcastMessage]] = [:]
    }

    private struct LocalEmployeeStoreLinksPayload: Codable {
        var storeIdsByEmployeeId: [String: [String]] = [:]
        var employeeNameById: [String: String]? = nil
        var employeeEmailById: [String: String]? = nil
        var employeeHourlyRateCentsById: [String: Int]? = nil
        var employeeExpectedStartMinutesById: [String: Int]? = nil
        var employeeIsActiveById: [String: Bool]? = nil
    }

    private func localFallbackStores() -> [Store] {
        let payload = loadLocalFallbackPayload()
        var mergedById: [String: Store] = [:]
        for stores in payload.storesByManagerId.values {
            for store in stores where store.isActive {
                mergedById[store.id] = store
            }
        }
        return mergedById.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func localFallbackStores(storeIDs: Set<String>) -> [Store] {
        guard !storeIDs.isEmpty else { return [] }
        return localFallbackStores().filter { storeIDs.contains($0.id) }
    }

    private func localFallbackStores(managerId: String) -> [Store] {
        let payload = loadLocalFallbackPayload()
        let stores = payload.storesByManagerId[managerId] ?? []
        return stores
            .filter(\.isActive)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func localFallbackStore(storeId: String, managerId: String) -> Store? {
        localFallbackStores(managerId: managerId).first { $0.id == storeId }
    }

    private func persistLocalFallbackStore(_ store: Store, managerId: String) {
        var payload = loadLocalFallbackPayload()
        var stores = payload.storesByManagerId[managerId] ?? []
        var updatedStore = store
        let now = Date()
        updatedStore.managerId = managerId
        updatedStore.createdAt = updatedStore.createdAt ?? now
        updatedStore.updatedAt = now
        if let code = updatedStore.resolvedJoinCode, !code.isEmpty {
            let normalizedCode = normalizeJoinCode(code)
            updatedStore.joinCode = normalizedCode
            updatedStore.joinCodeCiphertext = normalizedCode
            updatedStore.joinCodeLast4 = String(normalizedCode.suffix(4))
        }

        if let index = stores.firstIndex(where: { $0.id == updatedStore.id }) {
            stores[index] = updatedStore
        } else {
            stores.append(updatedStore)
        }

        payload.storesByManagerId[managerId] = stores
        saveLocalFallbackPayload(payload)
    }

    private func deleteLocalFallbackStore(storeId: String, managerId: String) {
        var payload = loadLocalFallbackPayload()
        var stores = payload.storesByManagerId[managerId] ?? []
        stores.removeAll { $0.id == storeId }
        payload.storesByManagerId[managerId] = stores
        saveLocalFallbackPayload(payload)
    }

    private func localFallbackStoreIDs(forEmployee employeeId: String) -> [String] {
        let payload = loadLocalEmployeeStoreLinksPayload()
        return Array(Set(payload.storeIdsByEmployeeId[employeeId] ?? [])).sorted()
    }

    private func setLocalFallbackStoreMembership(
        employeeId: String,
        storeId: String,
        isActive: Bool,
        employeeName: String?,
        employeeEmail: String?
    ) {
        var payload = loadLocalEmployeeStoreLinksPayload()
        var storeIDs = Set(payload.storeIdsByEmployeeId[employeeId] ?? [])
        var namesById = payload.employeeNameById ?? [:]
        var emailsById = payload.employeeEmailById ?? [:]
        if isActive {
            storeIDs.insert(storeId)
            if let employeeName, !employeeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                namesById[employeeId] = employeeName
            }
            if let employeeEmail, !employeeEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emailsById[employeeId] = employeeEmail
            }
        } else {
            storeIDs.remove(storeId)
        }
        if storeIDs.isEmpty {
            payload.storeIdsByEmployeeId.removeValue(forKey: employeeId)
            namesById.removeValue(forKey: employeeId)
            emailsById.removeValue(forKey: employeeId)
        } else {
            payload.storeIdsByEmployeeId[employeeId] = storeIDs.sorted()
        }
        payload.employeeNameById = namesById
        payload.employeeEmailById = emailsById
        saveLocalEmployeeStoreLinksPayload(payload)
    }

    private func joinLocalFallbackStoreByCode(
        normalizedCode: String,
        codeHash: String,
        currentUserId: String,
        employeeName: String?,
        employeeEmail: String?
    ) throws -> JoinStoreResult {
        let localStores = localFallbackStores()
        guard !localStores.isEmpty else {
            throw CloudKitClientError.invalidData(
                "Cloud sync is unavailable on this build, so join codes from other devices cannot be resolved yet."
            )
        }

        guard let store = localStores.first(where: { candidate in
            guard candidate.isActive,
                  let resolvedCode = candidate.resolvedJoinCode,
                  !resolvedCode.isEmpty else {
                return false
            }
            let normalizedCandidateCode = normalizeJoinCode(resolvedCode)
            return normalizedCandidateCode == normalizedCode || CloudKitService.stableHash(normalizedCandidateCode) == codeHash
        }) else {
            throw CloudKitClientError.invalidData(
                "Join code not found locally. Ask your manager for a fresh code from this device, or fix CloudKit container setup."
            )
        }

        let existingStoreIDs = Set(localFallbackStoreIDs(forEmployee: currentUserId))
        let alreadyJoined = existingStoreIDs.contains(store.id)
        setLocalFallbackStoreMembership(
            employeeId: currentUserId,
            storeId: store.id,
            isActive: true,
            employeeName: employeeName,
            employeeEmail: employeeEmail
        )
        let assignedStoreIds = Array(existingStoreIDs.union([store.id])).sorted()
        AppLog.warning("Join store used local fallback store=\(store.id) employee=\(AppLog.redactIdentifier(currentUserId))")

        return JoinStoreResult(
            storeId: store.id,
            storeName: store.name,
            alreadyJoined: alreadyJoined,
            assignedStoreIds: assignedStoreIds
        )
    }

    private func rotateLocalFallbackJoinCode(storeId: String, managerId: String) throws -> String {
        var payload = loadLocalFallbackPayload()
        var stores = payload.storesByManagerId[managerId] ?? []
        guard let index = stores.firstIndex(where: { $0.id == storeId }) else {
            throw CloudKitClientError.missingRecord("Store code not found.")
        }
        let code = Self.generateJoinCode()
        stores[index].joinCode = code
        stores[index].joinCodeCiphertext = code
        stores[index].joinCodeLast4 = String(code.suffix(4))
        stores[index].updatedAt = Date()
        payload.storesByManagerId[managerId] = stores
        saveLocalFallbackPayload(payload)
        return code
    }

    private func loadLocalFallbackPayload() -> LocalFallbackPayload {
        guard let data = UserDefaults.standard.data(forKey: Self.localFallbackStoresKey) else {
            return LocalFallbackPayload()
        }
        do {
            return try JSONDecoder().decode(LocalFallbackPayload.self, from: data)
        } catch {
            AppLog.warning("Local store fallback decode failed: \(AppLog.sanitize(error.localizedDescription))")
            return LocalFallbackPayload()
        }
    }

    private func saveLocalFallbackPayload(_ payload: LocalFallbackPayload) {
        do {
            let data = try JSONEncoder().encode(payload)
            UserDefaults.standard.set(data, forKey: Self.localFallbackStoresKey)
        } catch {
            AppLog.warning("Local store fallback encode failed: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func loadLocalEmployeeStoreLinksPayload() -> LocalEmployeeStoreLinksPayload {
        guard let data = UserDefaults.standard.data(forKey: Self.localFallbackEmployeeLinksKey) else {
            return LocalEmployeeStoreLinksPayload()
        }
        do {
            return try JSONDecoder().decode(LocalEmployeeStoreLinksPayload.self, from: data)
        } catch {
            AppLog.warning("Local employee membership fallback decode failed: \(AppLog.sanitize(error.localizedDescription))")
            return LocalEmployeeStoreLinksPayload()
        }
    }

    private func saveLocalEmployeeStoreLinksPayload(_ payload: LocalEmployeeStoreLinksPayload) {
        do {
            let data = try JSONEncoder().encode(payload)
            UserDefaults.standard.set(data, forKey: Self.localFallbackEmployeeLinksKey)
        } catch {
            AppLog.warning("Local employee membership fallback encode failed: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func loadLocalBroadcastPayload() -> LocalBroadcastPayload {
        guard let data = UserDefaults.standard.data(forKey: Self.localBroadcastMessagesKey) else {
            return LocalBroadcastPayload()
        }
        do {
            return try JSONDecoder().decode(LocalBroadcastPayload.self, from: data)
        } catch {
            AppLog.warning("Local broadcast fallback decode failed: \(AppLog.sanitize(error.localizedDescription))")
            return LocalBroadcastPayload()
        }
    }

    private func saveLocalBroadcastPayload(_ payload: LocalBroadcastPayload) {
        do {
            let data = try JSONEncoder().encode(payload)
            UserDefaults.standard.set(data, forKey: Self.localBroadcastMessagesKey)
        } catch {
            AppLog.warning("Local broadcast fallback encode failed: \(AppLog.sanitize(error.localizedDescription))")
        }
    }

    private func persistLocalBroadcastMessage(_ message: BroadcastMessage) {
        var payload = loadLocalBroadcastPayload()
        var items = payload.messagesByStoreId[message.storeId] ?? []
        if let index = items.firstIndex(where: { $0.id == message.id }) {
            items[index] = message
        } else {
            items.append(message)
        }
        payload.messagesByStoreId[message.storeId] = items.sorted { $0.createdAt > $1.createdAt }
        saveLocalBroadcastPayload(payload)
    }

    private func localBroadcastMessages(for storeId: String) -> [BroadcastMessage] {
        let payload = loadLocalBroadcastPayload()
        return (payload.messagesByStoreId[storeId] ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    private func decodeBroadcastMessage(record: CKRecord) -> BroadcastMessage? {
        guard let id = record.string(CKSchema.BroadcastField.messageId),
              let storeId = record.string(CKSchema.BroadcastField.storeId),
              let managerUserId = record.string(CKSchema.BroadcastField.managerUserId),
              let message = record.string(CKSchema.BroadcastField.message) else {
            return nil
        }
        return BroadcastMessage(
            id: id,
            storeId: storeId,
            storeName: record.string(CKSchema.BroadcastField.storeName) ?? "Store",
            managerUserId: managerUserId,
            managerName: record.string(CKSchema.BroadcastField.managerName) ?? "Manager",
            message: message,
            createdAt: record.date(CKSchema.BroadcastField.createdAt) ?? Date()
        )
    }

    private func mergeBroadcastMessages(preferred: [BroadcastMessage], fallback: [BroadcastMessage]) -> [BroadcastMessage] {
        var merged = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        for message in preferred {
            merged[message.id] = message
        }
        return merged.values.sorted { $0.createdAt > $1.createdAt }
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

    private static func generateQRCodeToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
}

private extension Optional where Wrapped == String {
    func flatMapAsync<T>(_ transform: (String) async -> T?) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
