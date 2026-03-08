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
    private let profileStore: UserProfileStoreProtocol

    init(service: CloudKitService, profileStore: UserProfileStoreProtocol) {
        self.service = service
        self.profileStore = profileStore
    }

    func ensureUserProfile(
        uid: String,
        name: String?,
        email: String?,
        provider: String,
        requestedRole: UserRole?
    ) async throws -> RoleBootstrapStatus {
        AppLog.info("Role profile bootstrap started for user=\(AppLog.redactIdentifier(uid)) requestedRole=\(requestedRole?.rawValue ?? "nil")")
        try await service.ensureCloudKitAvailable()
        AppLog.info("CloudKit availability confirmed for user=\(AppLog.redactIdentifier(uid))")

        let now = Date()
        let normalizedName = normalizeName(name)
        let normalizedEmail = normalizeEmail(email)

        let canonicalProfile = try await profileStore.fetchCanonicalProfile(userId: uid)
        AppLog.info("Canonical profile lookup for user=\(AppLog.redactIdentifier(uid)) result=\(canonicalProfile == nil ? "missing" : "found")")
        let publicProfile: UserProfile?
        if canonicalProfile == nil {
            AppLog.info("Falling back to public profile lookup for user=\(AppLog.redactIdentifier(uid))")
            publicProfile = try await fetchPublicProfileRecovering(userId: uid)
            AppLog.info("Public profile lookup for user=\(AppLog.redactIdentifier(uid)) result=\(publicProfile == nil ? "missing" : "found")")
        } else {
            publicProfile = nil
        }

        let existingProfile = canonicalProfile ?? publicProfile
        let resolvedRole = existingProfile?.role ?? requestedRole
        guard let resolvedRole else {
            AppLog.warning("Role bootstrap requires setup for user=\(AppLog.redactIdentifier(uid)); no role resolved")
            return .setupRequired
        }

        var profile = existingProfile ?? UserProfile(
            id: uid,
            name: normalizedName ?? fallbackName(from: normalizedEmail ?? email),
            email: normalizedEmail,
            role: resolvedRole,
            createdAt: now,
            lastLoginAt: now,
            provider: provider,
            assignedStoreIds: [],
            isActive: true
        )

        if existingProfile == nil {
            profile.role = resolvedRole
        }

        if let normalizedName {
            profile.name = normalizedName
        }

        if let normalizedEmail {
            profile.email = normalizedEmail
        }

        profile.provider = provider
        profile.lastLoginAt = now
        if profile.createdAt > now {
            profile.createdAt = now
        }

        AppLog.info(
            "Persisting canonical profile for user=\(AppLog.redactIdentifier(uid)) role=\(profile.role.rawValue) active=\(profile.isActive)"
        )
        let savedCanonical: UserProfile
        do {
            savedCanonical = try await profileStore.upsertCanonicalProfile(profile, deletedAt: profile.isActive ? nil : now)
            AppLog.info("Canonical profile upsert succeeded for user=\(AppLog.redactIdentifier(uid))")
        } catch {
            guard isRecoverableProfilePersistenceError(error) else {
                throw error
            }
            AppLog.warning(
                "Canonical profile persistence skipped for user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))"
            )
            savedCanonical = profile
        }

        await profileStore.upsertPublicProfileBestEffort(savedCanonical, deletedAt: savedCanonical.isActive ? nil : now)
        AppLog.info("Public profile mirror attempted for user=\(AppLog.redactIdentifier(uid))")

        await service.bootstrapSubscriptions(for: uid, role: savedCanonical.role)
        AppLog.info("Role profile bootstrap finished for user=\(AppLog.redactIdentifier(uid)) role=\(savedCanonical.role.rawValue)")
        return .resolved(profileFromUser(savedCanonical))
    }

    func fetchUserProfile(uid: String) async throws -> UserAccessProfile? {
        try await service.ensureCloudKitAvailable()

        if let canonical = try await profileStore.fetchCanonicalProfile(userId: uid) {
            return profileFromUser(canonical)
        }

        guard let publicProfile = try await fetchPublicProfileRecovering(userId: uid) else {
            return nil
        }

        do {
            let seededCanonical = try await profileStore.upsertCanonicalProfile(publicProfile, deletedAt: publicProfile.isActive ? nil : Date())
            return profileFromUser(seededCanonical)
        } catch {
            guard isRecoverableProfilePersistenceError(error) else {
                throw error
            }
            AppLog.warning(
                "Skipping canonical backfill for fetched public profile user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))"
            )
            return profileFromUser(publicProfile)
        }
    }

    func updateDisplayName(uid: String, name: String) async throws -> UserAccessProfile {
        try await service.ensureCloudKitAvailable()

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw CloudKitClientError.invalidData("Please enter your name.")
        }

        guard let existingProfile = try await resolveAnyProfile(userId: uid) else {
            throw CloudKitClientError.missingRecord("Profile not found.")
        }

        var updatedProfile = existingProfile
        updatedProfile.name = normalizedName
        updatedProfile.lastLoginAt = Date()

        do {
            let saved = try await profileStore.upsertCanonicalProfile(updatedProfile, deletedAt: updatedProfile.isActive ? nil : Date())
            await profileStore.upsertPublicProfileBestEffort(saved, deletedAt: saved.isActive ? nil : Date())
            return profileFromUser(saved)
        } catch {
            guard isRecoverableProfilePersistenceError(error) else {
                throw error
            }
            await profileStore.upsertPublicProfileBestEffort(updatedProfile, deletedAt: updatedProfile.isActive ? nil : Date())
            AppLog.warning(
                "Display name updated in-memory/public best-effort only for user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))"
            )
            return profileFromUser(updatedProfile)
        }
    }

    func softDeleteAccount(uid: String, role: UserRole) async throws {
        try await service.ensureCloudKitAvailable()

        let now = Date()

        let existingProfile: UserProfile?
        do {
            existingProfile = try await resolveAnyProfile(userId: uid)
        } catch {
            guard isRecoverableProfilePersistenceError(error) else {
                throw error
            }
            AppLog.warning("Profile lookup skipped during account deletion user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))")
            existingProfile = nil
        }

        if var deactivatedProfile = existingProfile {
            deactivatedProfile.isActive = false
            deactivatedProfile.assignedStoreIds = []
            deactivatedProfile.lastLoginAt = now

            do {
                _ = try await profileStore.upsertCanonicalProfile(deactivatedProfile, deletedAt: now)
            } catch {
                guard isRecoverableProfilePersistenceError(error) else {
                    throw error
                }
                AppLog.warning("Canonical profile deactivation skipped for user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))")
            }
            await profileStore.upsertPublicProfileBestEffort(deactivatedProfile, deletedAt: now)
        }

        var recordIDsToDelete: [CKRecord.ID] = [CloudKitService.userRecordID(userId: uid)]
        var employeeIdsToSync = Set<String>()

        switch role {
        case .employee:
            do {
                let memberships = try await service.queryRecords(
                    recordType: CKSchema.RecordType.storeMember,
                    predicate: NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.employeeUserId, uid)
                )
                recordIDsToDelete.append(contentsOf: memberships.map(\.recordID))
            } catch {
                guard isRecoverableProfilePersistenceError(error) else {
                    throw error
                }
                AppLog.warning("Employee membership delete query skipped user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))")
            }

            do {
                let employeeCheckIns = try await service.queryRecords(
                    recordType: CKSchema.RecordType.checkInSession,
                    predicate: NSPredicate(format: "%K == %@", CKSchema.CheckInField.employeeUserId, uid)
                )
                recordIDsToDelete.append(contentsOf: employeeCheckIns.map(\.recordID))
            } catch {
                guard isRecoverableProfilePersistenceError(error) else {
                    throw error
                }
                AppLog.warning("Employee check-in delete query skipped user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))")
            }

        case .manager:
            do {
                let managerStores = try await service.queryRecords(
                    recordType: CKSchema.RecordType.store,
                    predicate: NSPredicate(format: "%K == %@", CKSchema.StoreField.managerUserId, uid)
                )

                for store in managerStores {
                    recordIDsToDelete.append(store.recordID)
                    if let storeId = store.string(CKSchema.StoreField.storeId) {
                        do {
                            let memberships = try await service.queryRecords(
                                recordType: CKSchema.RecordType.storeMember,
                                predicate: NSPredicate(format: "%K == %@", CKSchema.StoreMemberField.storeId, storeId)
                            )
                            for membership in memberships {
                                if let employeeId = membership.string(CKSchema.StoreMemberField.employeeUserId) {
                                    employeeIdsToSync.insert(employeeId)
                                }
                            }
                            recordIDsToDelete.append(contentsOf: memberships.map(\.recordID))
                        } catch {
                            guard isRecoverableProfilePersistenceError(error) else {
                                throw error
                            }
                            AppLog.warning("Store membership delete query skipped store=\(storeId): \(AppLog.sanitize(error.localizedDescription))")
                        }

                        do {
                            let checkIns = try await service.queryRecords(
                                recordType: CKSchema.RecordType.checkInSession,
                                predicate: NSPredicate(format: "%K == %@", CKSchema.CheckInField.storeId, storeId)
                            )
                            recordIDsToDelete.append(contentsOf: checkIns.map(\.recordID))
                        } catch {
                            guard isRecoverableProfilePersistenceError(error) else {
                                throw error
                            }
                            AppLog.warning("Store check-in delete query skipped store=\(storeId): \(AppLog.sanitize(error.localizedDescription))")
                        }
                    }
                }
            } catch {
                guard isRecoverableProfilePersistenceError(error) else {
                    throw error
                }
                AppLog.warning("Manager store delete query skipped user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))")
            }
        }

        let uniqueRecordIDs = Array(Set(recordIDsToDelete.map(\.recordName))).map { CKRecord.ID(recordName: $0) }
        if !uniqueRecordIDs.isEmpty {
            do {
                _ = try await service.modify(recordsToSave: [], recordIDsToDelete: uniqueRecordIDs, atomic: false)
            } catch {
                guard isRecoverableProfilePersistenceError(error) else {
                    throw error
                }
                AppLog.warning("Public record delete batch skipped for user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))")
            }
        }

        do {
            try await service.deleteRecord(with: CloudKitService.userRecordID(userId: uid), in: service.privateDB)
        } catch {
            guard isRecoverableProfilePersistenceError(error) else {
                throw error
            }
            AppLog.warning("Private user record delete skipped for user=\(AppLog.redactIdentifier(uid)): \(AppLog.sanitize(error.localizedDescription))")
        }

        for employeeId in employeeIdsToSync {
            do {
                if var employee = try await profileStore.fetchCanonicalProfile(userId: employeeId) {
                    employee.assignedStoreIds = []
                    employee.lastLoginAt = Date()
                    _ = try await profileStore.upsertCanonicalProfile(employee, deletedAt: employee.isActive ? nil : Date())
                    await profileStore.upsertPublicProfileBestEffort(employee, deletedAt: employee.isActive ? nil : Date())
                }
            } catch {
                AppLog.warning("Employee profile sync skipped after manager deletion user=\(AppLog.redactIdentifier(employeeId)): \(AppLog.sanitize(error.localizedDescription))")
            }
        }
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

    private func fetchPublicProfileRecovering(userId: String) async throws -> UserProfile? {
        do {
            return try await profileStore.fetchPublicProfile(userId: userId)
        } catch {
            if isRecoverablePublicLookupError(error) {
                AppLog.warning(
                    "Recoverable public profile lookup error for user=\(AppLog.redactIdentifier(userId)): \(AppLog.sanitize(error.localizedDescription))"
                )
                return nil
            }
            AppLog.error(
                "Non-recoverable public profile lookup error for user=\(AppLog.redactIdentifier(userId))",
                error: error
            )
            throw error
        }
    }

    private func resolveAnyProfile(userId: String) async throws -> UserProfile? {
        if let canonical = try await profileStore.fetchCanonicalProfile(userId: userId) {
            return canonical
        }
        return try await fetchPublicProfileRecovering(userId: userId)
    }

    private func isRecoverablePublicLookupError(_ error: Error) -> Bool {
        if let clientError = error as? CloudKitClientError,
           case .invalidData(let message) = clientError,
           message.localizedCaseInsensitiveContains("invalid bundle id for container") {
            AppLog.warning("Treating CloudKit identity mismatch as recoverable during public lookup")
            return true
        }

        if let clientError = error as? CloudKitClientError,
           case .unauthorized = clientError {
            AppLog.warning("Treating CloudKitClientError.unauthorized as recoverable during public lookup")
            return true
        }

        guard let ckError = error as? CKError else {
            let description = error.localizedDescription.lowercased()
            return description.contains("record type") ||
                description.contains("schema") ||
                description.contains("unknown field")
        }

        switch ckError.code {
        case .permissionFailure, .unknownItem, .invalidArguments, .serverRejectedRequest, .partialFailure:
            AppLog.warning("Treating CKError \(ckError.code.rawValue) as recoverable during public lookup")
            return true
        default:
            return false
        }
    }

    private func isRecoverableProfilePersistenceError(_ error: Error) -> Bool {
        if isRecoverablePublicLookupError(error) {
            return true
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("record type") ||
            description.contains("schema") ||
            description.contains("unknown field")
    }

    private func profileFromUser(_ user: UserProfile) -> UserAccessProfile {
        UserAccessProfile(
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
