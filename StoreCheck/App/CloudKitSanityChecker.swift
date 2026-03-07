import CloudKit
import Foundation

struct CloudKitSanityReport {
    let generatedAt: Date
    let lines: [String]
    let issueCount: Int

    var renderedText: String {
        lines.joined(separator: "\n")
    }
}

@MainActor
protocol CloudKitSanityChecking {
    func run(currentUserId: String?) async -> CloudKitSanityReport
}

@MainActor
final class CloudKitSanityChecker: CloudKitSanityChecking {
    private let service: CloudKitService

    init(service: CloudKitService) {
        self.service = service
    }

    func run(currentUserId: String?) async -> CloudKitSanityReport {
        let startedAt = Date()
        var lines: [String] = []
        var issueCount = 0

        func append(_ message: String) {
            lines.append(message)
            AppLog.info("[Sanity] \(message)")
        }

        func issue(_ message: String) {
            lines.append("ISSUE: \(message)")
            AppLog.warning("[Sanity] \(message)")
            issueCount += 1
        }

        append("CloudKit integrity check started at \(ISO8601DateFormatter().string(from: startedAt))")
        append("Container: \(service.container.containerIdentifier ?? "default")")
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        append("Expected container for bundle: iCloud.\(bundleID)")
        let signing = SigningDiagnostics.snapshot()
        append("Signed app identifier: \(signing.applicationIdentifier ?? "unknown")")
        append(
            "Signed iCloud containers: " +
            (signing.iCloudContainerIdentifiers.isEmpty ? "none" : signing.iCloudContainerIdentifiers.joined(separator: ","))
        )
        append("Current user: \(currentUserId.map { AppLog.redactIdentifier($0) } ?? "none")")

        do {
            try await service.ensureCloudKitAvailable()
            append("CloudKit account: available")
        } catch {
            issue("CloudKit unavailable: \(AppLog.sanitize(error.localizedDescription))")
            return CloudKitSanityReport(generatedAt: startedAt, lines: lines, issueCount: issueCount)
        }

        let users = await queryRecords(recordType: CKSchema.RecordType.user, scope: "public", in: service.publicDB, lines: &lines, issueCount: &issueCount)
        let legacyUsers = await queryRecords(recordType: CKSchema.RecordType.legacyUsers, scope: "public", in: service.publicDB, lines: &lines, issueCount: &issueCount)
        let stores = await queryRecords(recordType: CKSchema.RecordType.store, scope: "public", in: service.publicDB, lines: &lines, issueCount: &issueCount)
        let memberships = await queryRecords(recordType: CKSchema.RecordType.storeMember, scope: "public", in: service.publicDB, lines: &lines, issueCount: &issueCount)
        let checkIns = await queryRecords(recordType: CKSchema.RecordType.checkInSession, scope: "public", in: service.publicDB, lines: &lines, issueCount: &issueCount)

        let allProfiles = users + legacyUsers
        let userIds = Set(allProfiles.compactMap { $0.string(CKSchema.UserField.userId) })

        var storesById: [String: CKRecord] = [:]
        var duplicateStoreIds = Set<String>()
        for record in stores {
            guard let storeId = record.string(CKSchema.StoreField.storeId) else {
                issue("Store record missing storeId: \(record.recordID.recordName)")
                continue
            }
            if storesById[storeId] != nil {
                duplicateStoreIds.insert(storeId)
            }
            storesById[storeId] = record

            let managerId = record.string(CKSchema.StoreField.managerUserId)
            if managerId?.isEmpty ?? true {
                issue("Store \(storeId) has no managerUserId")
            } else if let managerId, !userIds.contains(managerId) {
                issue("Store \(storeId) points to missing manager profile \(AppLog.redactIdentifier(managerId))")
            }
        }

        for duplicate in duplicateStoreIds.sorted() {
            issue("Duplicate storeId detected: \(duplicate)")
        }

        let duplicateUserIds = duplicates(from: allProfiles.compactMap { $0.string(CKSchema.UserField.userId) })
        for duplicate in duplicateUserIds.sorted() {
            issue("Duplicate user profile id detected: \(AppLog.redactIdentifier(duplicate))")
        }

        var membershipKeys = Set<String>()
        var duplicateMembershipKeys = Set<String>()
        for membership in memberships {
            guard let storeId = membership.string(CKSchema.StoreMemberField.storeId), !storeId.isEmpty else {
                issue("Membership \(membership.recordID.recordName) missing storeId")
                continue
            }
            guard let employeeId = membership.string(CKSchema.StoreMemberField.employeeUserId), !employeeId.isEmpty else {
                issue("Membership \(membership.recordID.recordName) missing employeeUserId")
                continue
            }

            let key = "\(storeId)|\(employeeId)"
            if !membershipKeys.insert(key).inserted {
                duplicateMembershipKeys.insert(key)
            }

            if storesById[storeId] == nil {
                issue("Membership \(membership.recordID.recordName) points to missing store \(storeId)")
            }

            if !userIds.contains(employeeId) {
                issue("Membership \(membership.recordID.recordName) points to missing employee \(AppLog.redactIdentifier(employeeId))")
            }

            if let storeReference = membership[CKSchema.StoreMemberField.storeRef] as? CKRecord.Reference,
               storeReference.recordID != CloudKitService.storeRecordID(storeId: storeId) {
                issue("Membership \(membership.recordID.recordName) has broken storeRef for storeId \(storeId)")
            }

            if let employeeReference = membership[CKSchema.StoreMemberField.employeeUserRef] as? CKRecord.Reference,
               employeeReference.recordID != CloudKitService.userRecordID(userId: employeeId) {
                issue("Membership \(membership.recordID.recordName) has broken employeeUserRef for employee \(AppLog.redactIdentifier(employeeId))")
            }
        }

        for duplicate in duplicateMembershipKeys.sorted() {
            issue("Duplicate membership detected for key \(duplicate)")
        }

        let duplicateCheckInIds = duplicates(from: checkIns.compactMap { $0.string(CKSchema.CheckInField.sessionId) })
        for duplicate in duplicateCheckInIds.sorted() {
            issue("Duplicate check-in sessionId detected: \(duplicate)")
        }

        for checkIn in checkIns {
            guard let sessionId = checkIn.string(CKSchema.CheckInField.sessionId), !sessionId.isEmpty else {
                issue("CheckIn record \(checkIn.recordID.recordName) missing sessionId")
                continue
            }

            guard let storeId = checkIn.string(CKSchema.CheckInField.storeId), !storeId.isEmpty else {
                issue("CheckIn \(sessionId) missing storeId")
                continue
            }

            guard let employeeId = checkIn.string(CKSchema.CheckInField.employeeUserId), !employeeId.isEmpty else {
                issue("CheckIn \(sessionId) missing employeeUserId")
                continue
            }

            if storesById[storeId] == nil {
                issue("CheckIn \(sessionId) references missing store \(storeId)")
            }

            if !userIds.contains(employeeId) {
                issue("CheckIn \(sessionId) references missing employee \(AppLog.redactIdentifier(employeeId))")
            }

            if let managerId = checkIn.string(CKSchema.CheckInField.managerUserId),
               let storeManagerId = storesById[storeId]?.string(CKSchema.StoreField.managerUserId),
               managerId != storeManagerId {
                issue("CheckIn \(sessionId) manager mismatch. session=\(AppLog.redactIdentifier(managerId)) store=\(AppLog.redactIdentifier(storeManagerId))")
            }

            if let checkInAt = checkIn.date(CKSchema.CheckInField.checkInAt),
               let checkOutAt = checkIn.date(CKSchema.CheckInField.checkOutAt),
               checkOutAt < checkInAt {
                issue("CheckIn \(sessionId) has checkOutAt earlier than checkInAt")
            }
        }

        if issueCount == 0 {
            append("Integrity checks passed: no issues found.")
        } else {
            append("Integrity checks completed with \(issueCount) issue(s).")
        }

        return CloudKitSanityReport(generatedAt: startedAt, lines: lines, issueCount: issueCount)
    }

    private func queryRecords(
        recordType: String,
        scope: String,
        in database: CKDatabase,
        lines: inout [String],
        issueCount: inout Int
    ) async -> [CKRecord] {
        do {
            let records = try await service.queryRecords(
                recordType: recordType,
                predicate: NSPredicate(value: true),
                in: database
            )
            let message = "\(scope) \(recordType): \(records.count)"
            lines.append(message)
            AppLog.info("[Sanity] \(message)")
            return records
        } catch {
            let message = "Unable to query \(scope) \(recordType): \(AppLog.sanitize(error.localizedDescription))"
            lines.append("ISSUE: \(message)")
            AppLog.warning("[Sanity] \(message)")
            issueCount += 1
            return []
        }
    }

    private func duplicates(from values: [String]) -> Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for value in values {
            if !seen.insert(value).inserted {
                duplicates.insert(value)
            }
        }
        return duplicates
    }
}
