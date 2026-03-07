import CloudKit
import Foundation

struct UserAccessProfile: Equatable {
    let id: String
    let name: String
    let email: String?
    let role: UserRole
    let isActive: Bool
    let provider: String
    let createdAt: Date
    let lastLoginAt: Date
    let assignedStoreIds: [String]
}

enum RoleBootstrapStatus: Equatable {
    case resolved(UserAccessProfile)
    case setupRequired
}

struct ManagerProfile {
    let id: String
    let name: String
    let email: String?
    let createdAt: Date
    let lastLoginAt: Date
    let isActive: Bool
}

struct EmployeeProfile {
    let id: String
    let name: String
    let email: String?
    let createdAt: Date
    let lastLoginAt: Date
    let isActive: Bool
    let assignedStoreIds: [String]
}

@MainActor
protocol RoleProfileRepositoryProtocol {
    func ensureUserProfile(
        uid: String,
        name: String?,
        email: String?,
        provider: String,
        requestedRole: UserRole?
    ) async throws -> RoleBootstrapStatus

    func fetchUserProfile(uid: String) async throws -> UserAccessProfile?
    func updateDisplayName(uid: String, name: String) async throws -> UserAccessProfile
    func softDeleteAccount(uid: String, role: UserRole) async throws
}

@MainActor
final class CloudKitRoleProfileRepository: RoleProfileRepositoryProtocol {
    private let service: CloudKitService

    init(service: CloudKitService) {
        self.service = service
    }

    func ensureUserProfile(
        uid: String,
        name: String?,
        email: String?,
        provider: String,
        requestedRole: UserRole?
    ) async throws -> RoleBootstrapStatus {
        try await service.ensureCloudKitAvailable()

        let recordID = CloudKitService.userRecordID(userId: uid)
        let now = Date()
        let existingRecord: CKRecord?
        do {
            existingRecord = try await fetchAnyUserRecord(uid: uid, preferredRecordID: recordID)
        } catch CloudKitClientError.unauthorized {
            // Some schemas block reads before first write; continue and attempt profile creation path.
            existingRecord = nil
        }

        if let existing = existingRecord {
            let currentRole = UserRole(rawValue: existing.string(CKSchema.UserField.role) ?? "")
            let role = currentRole ?? requestedRole
            guard let role else {
                return .setupRequired
            }

            var sourceRecord = existing
            if let writableRecord = existing.copy() as? CKRecord {
                writableRecord[CKSchema.UserField.userId] = uid as CKRecordValue
                writableRecord[CKSchema.UserField.role] = role.rawValue as CKRecordValue
                writableRecord[CKSchema.UserField.provider] = provider as CKRecordValue
                writableRecord[CKSchema.UserField.updatedAt] = now as CKRecordValue

                let normalizedName = normalizeName(name)
                if let normalizedName {
                    writableRecord[CKSchema.UserField.name] = normalizedName as CKRecordValue
                }

                let normalizedEmail = normalizeEmail(email)
                if let normalizedEmail {
                    writableRecord[CKSchema.UserField.email] = normalizedEmail as CKRecordValue
                }

                if writableRecord[CKSchema.UserField.createdAt] == nil {
                    writableRecord[CKSchema.UserField.createdAt] = now as CKRecordValue
                }
                if writableRecord[CKSchema.UserField.isActive] == nil {
                    writableRecord[CKSchema.UserField.isActive] = NSNumber(value: true)
                }
                if writableRecord[CKSchema.UserField.assignedStoreIds] == nil {
                    writableRecord[CKSchema.UserField.assignedStoreIds] = [] as CKRecordValue
                }

                do {
                    sourceRecord = try await service.save(record: writableRecord)
                } catch CloudKitClientError.unauthorized {
                    // Read-only profile access is enough to complete sign-in when server-side rules block updates.
                    AppLog.warning("User profile is read-only for uid=\(AppLog.redactIdentifier(uid)); continuing with existing data.")
                    sourceRecord = existing
                }
            }

            guard let profile = profileFromUserRecord(sourceRecord) else {
                throw CloudKitClientError.invalidData("Unable to load your profile.")
            }

            await service.bootstrapSubscriptions(for: uid, role: profile.role)
            return .resolved(profile)
        }

        guard let requestedRole else {
            return .setupRequired
        }

        let newRecord = CKRecord(recordType: CKSchema.RecordType.user, recordID: recordID)
        newRecord[CKSchema.UserField.userId] = uid as CKRecordValue
        newRecord[CKSchema.UserField.role] = requestedRole.rawValue as CKRecordValue
        newRecord[CKSchema.UserField.provider] = provider as CKRecordValue
        newRecord[CKSchema.UserField.name] = (normalizeName(name) ?? fallbackName(from: email)) as CKRecordValue
        if let normalizedEmail = normalizeEmail(email) {
            newRecord[CKSchema.UserField.email] = normalizedEmail as CKRecordValue
        }
        newRecord[CKSchema.UserField.isActive] = NSNumber(value: true)
        newRecord[CKSchema.UserField.assignedStoreIds] = [] as CKRecordValue
        newRecord[CKSchema.UserField.createdAt] = now as CKRecordValue
        newRecord[CKSchema.UserField.updatedAt] = now as CKRecordValue

        do {
            _ = try await service.save(record: newRecord)
        } catch CloudKitClientError.unauthorized {
            // Some production environments block user self-provisioning. Retry lookup in case the account exists with a non-standard ID.
            if let existing = try await fetchAnyUserRecord(uid: uid, preferredRecordID: recordID),
               let profile = profileFromUserRecord(existing) {
                await service.bootstrapSubscriptions(for: uid, role: profile.role)
                return .resolved(profile)
            }

            // Compatibility fallback: some containers only expose the legacy built-in "Users" type.
            let legacyRecord = CKRecord(recordType: CKSchema.RecordType.legacyUsers, recordID: recordID)
            legacyRecord[CKSchema.UserField.userId] = uid as CKRecordValue
            legacyRecord[CKSchema.UserField.role] = requestedRole.rawValue as CKRecordValue
            legacyRecord[CKSchema.UserField.provider] = provider as CKRecordValue
            legacyRecord[CKSchema.UserField.name] = (normalizeName(name) ?? fallbackName(from: email)) as CKRecordValue
            if let normalizedEmail = normalizeEmail(email) {
                legacyRecord[CKSchema.UserField.email] = normalizedEmail as CKRecordValue
            }
            legacyRecord[CKSchema.UserField.isActive] = NSNumber(value: true)
            legacyRecord[CKSchema.UserField.assignedStoreIds] = [] as CKRecordValue
            legacyRecord[CKSchema.UserField.createdAt] = now as CKRecordValue
            legacyRecord[CKSchema.UserField.updatedAt] = now as CKRecordValue

            do {
                _ = try await service.save(record: legacyRecord)
                if let legacyProfile = try await fetchUserProfile(uid: uid) {
                    await service.bootstrapSubscriptions(for: uid, role: legacyProfile.role)
                    return .resolved(legacyProfile)
                }
            } catch {
                AppLog.warning("Legacy Users fallback failed: \(AppLog.sanitize(error.localizedDescription))")
            }

            throw CloudKitClientError.invalidData(
                "CloudKit blocked account setup. In CloudKit Dashboard, allow authenticated users to create/write User (or Users) records."
            )
        }

        guard let profile = try await fetchUserProfile(uid: uid) else {
            throw CloudKitClientError.invalidData("Unable to create your profile.")
        }

        await service.bootstrapSubscriptions(for: uid, role: profile.role)
        return .resolved(profile)
    }

    func fetchUserProfile(uid: String) async throws -> UserAccessProfile? {
        try await service.ensureCloudKitAvailable()
        let recordID = CloudKitService.userRecordID(userId: uid)
        guard let record = try await fetchAnyUserRecord(uid: uid, preferredRecordID: recordID),
              let profile = profileFromUserRecord(record) else {
            return nil
        }

        return profile
    }

    func updateDisplayName(uid: String, name: String) async throws -> UserAccessProfile {
        try await service.ensureCloudKitAvailable()

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw CloudKitClientError.invalidData("Please enter your name.")
        }

        let recordID = CloudKitService.userRecordID(userId: uid)
        guard let record = try await service.fetchRecord(with: recordID) else {
            throw CloudKitClientError.missingRecord("Profile not found.")
        }

        record[CKSchema.UserField.name] = normalizedName as CKRecordValue
        record[CKSchema.UserField.updatedAt] = Date() as CKRecordValue

        _ = try await service.save(record: record)

        guard let profile = try await fetchUserProfile(uid: uid) else {
            throw CloudKitClientError.invalidData("Failed to refresh profile after update.")
        }

        return profile
    }

    func softDeleteAccount(uid: String, role: UserRole) async throws {
        try await service.ensureCloudKitAvailable()

        let now = Date()
        let userRecordID = CloudKitService.userRecordID(userId: uid)
        guard let userRecord = try await service.fetchRecord(with: userRecordID) else {
            throw CloudKitClientError.missingRecord("Account not found.")
        }

        userRecord[CKSchema.UserField.isActive] = NSNumber(value: false)
        userRecord[CKSchema.UserField.assignedStoreIds] = [] as CKRecordValue
        userRecord[CKSchema.UserField.updatedAt] = now as CKRecordValue
        userRecord[CKSchema.UserField.deletedAt] = now as CKRecordValue

        var recordsToSave: [CKRecord] = [userRecord]

        switch role {
        case .employee:
            let memberships = try await service.queryRecords(
                recordType: CKSchema.RecordType.storeMember,
                predicate: NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.employeeUserId, uid)
            )
            for membership in memberships {
                membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.removed as CKRecordValue
                membership[CKSchema.StoreMemberField.updatedAt] = now as CKRecordValue
                recordsToSave.append(membership)
            }

        case .manager:
            let managerStores = try await service.queryRecords(
                recordType: CKSchema.RecordType.store,
                predicate: NSPredicate(format: "%K == %@", CKSchema.StoreField.managerUserId, uid)
            )

            for store in managerStores {
                store[CKSchema.StoreField.isActive] = NSNumber(value: false)
                store[CKSchema.StoreField.updatedAt] = now as CKRecordValue
                store[CKSchema.StoreField.deletedAt] = now as CKRecordValue
                recordsToSave.append(store)

                if let storeId = store.string(CKSchema.StoreField.storeId) {
                    let memberships = try await service.queryRecords(
                        recordType: CKSchema.RecordType.storeMember,
                        predicate: NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.storeId, storeId)
                    )
                    for membership in memberships {
                        membership[CKSchema.StoreMemberField.status] = CKSchema.MemberStatus.removed as CKRecordValue
                        membership[CKSchema.StoreMemberField.updatedAt] = now as CKRecordValue
                        recordsToSave.append(membership)
                    }
                }
            }
        }

        _ = try await service.modify(recordsToSave: deduplicate(records: recordsToSave), atomic: false)
    }

    private func normalizeName(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizeEmail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private func fallbackName(from email: String?) -> String {
        guard let email = normalizeEmail(email), let raw = email.split(separator: "@").first else {
            return "StorePass User"
        }

        let parts = raw
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")

        if parts.isEmpty {
            return "StorePass User"
        }

        return parts.map {
            let lower = String($0).lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        .joined(separator: " ")
    }

    private func deduplicate(records: [CKRecord]) -> [CKRecord] {
        var seen = Set<String>()
        var unique: [CKRecord] = []
        for record in records {
            let key = record.recordID.recordName
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(record)
        }
        return unique
    }

    private func fetchAnyUserRecord(uid: String, preferredRecordID: CKRecord.ID) async throws -> CKRecord? {
        if let direct = try await service.fetchRecord(with: preferredRecordID) {
            return direct
        }

        let fallback = try await service.queryRecords(
            recordType: CKSchema.RecordType.user,
            predicate: NSPredicate(format: "%K == %@", CKSchema.UserField.userId, uid),
            sortDescriptors: [NSSortDescriptor(key: CKSchema.UserField.updatedAt, ascending: false)],
            resultsLimit: 1
        )
        if let first = fallback.first {
            return first
        }

        // Backward compatibility for earlier schema versions that used the built-in "Users" type.
        let legacyFallback = try await service.queryRecords(
            recordType: CKSchema.RecordType.legacyUsers,
            predicate: NSPredicate(format: "%K == %@", CKSchema.UserField.userId, uid),
            sortDescriptors: [NSSortDescriptor(key: CKSchema.UserField.updatedAt, ascending: false)],
            resultsLimit: 1
        )
        return legacyFallback.first
    }

    private func profileFromUserRecord(_ record: CKRecord) -> UserAccessProfile? {
        guard let user = decodeUserProfile(record: record) else {
            return nil
        }

        return UserAccessProfile(
            id: user.id,
            name: user.name,
            email: user.email,
            role: user.role,
            isActive: user.isActive,
            provider: user.provider,
            createdAt: user.createdAt,
            lastLoginAt: user.lastLoginAt,
            assignedStoreIds: user.assignedStoreIds
        )
    }
}
