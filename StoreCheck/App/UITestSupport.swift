#if DEBUG
import Foundation

@MainActor
final class UITestRoleProfileRepository: RoleProfileRepositoryProtocol {
    private var profilesById: [String: UserAccessProfile] = [:]

    func ensureUserProfile(
        uid: String,
        name: String?,
        email: String?,
        provider: String,
        requestedRole: UserRole?
    ) async throws -> RoleBootstrapStatus {
        let resolvedRole = profilesById[uid]?.role ?? requestedRole ?? .employee
        let now = Date()
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (normalizedName?.isEmpty == false ? normalizedName : nil) ?? "UI Test User"
        let profile = UserAccessProfile(
            id: uid,
            name: displayName,
            email: email,
            role: resolvedRole,
            isActive: true,
            provider: provider,
            createdAt: profilesById[uid]?.createdAt ?? now,
            lastLoginAt: now,
            assignedStoreIds: profilesById[uid]?.assignedStoreIds ?? []
        )
        profilesById[uid] = profile
        return .resolved(profile)
    }

    func fetchUserProfile(uid: String) async throws -> UserAccessProfile? {
        profilesById[uid]
    }

    func updateDisplayName(uid: String, name: String) async throws -> UserAccessProfile {
        guard var existing = profilesById[uid] else {
            throw CloudKitClientError.missingRecord("Profile not found.")
        }
        existing = UserAccessProfile(
            id: existing.id,
            name: name,
            email: existing.email,
            role: existing.role,
            isActive: existing.isActive,
            provider: existing.provider,
            createdAt: existing.createdAt,
            lastLoginAt: Date(),
            assignedStoreIds: existing.assignedStoreIds
        )
        profilesById[uid] = existing
        return existing
    }

    func softDeleteAccount(uid: String, role: UserRole) async throws {
        _ = role
        guard let existing = profilesById[uid] else {
            return
        }
        profilesById[uid] = UserAccessProfile(
            id: existing.id,
            name: existing.name,
            email: existing.email,
            role: existing.role,
            isActive: false,
            provider: existing.provider,
            createdAt: existing.createdAt,
            lastLoginAt: Date(),
            assignedStoreIds: []
        )
    }

    func setAssignedStoreIds(_ storeIds: [String], for uid: String) {
        guard let existing = profilesById[uid] else {
            return
        }
        profilesById[uid] = UserAccessProfile(
            id: existing.id,
            name: existing.name,
            email: existing.email,
            role: existing.role,
            isActive: existing.isActive,
            provider: existing.provider,
            createdAt: existing.createdAt,
            lastLoginAt: Date(),
            assignedStoreIds: storeIds.sorted()
        )
    }

    func userProfile(for uid: String) -> UserProfile? {
        guard let profile = profilesById[uid] else {
            return nil
        }
        return UserProfile(
            id: profile.id,
            name: profile.name,
            email: profile.email,
            role: profile.role,
            createdAt: profile.createdAt,
            lastLoginAt: profile.lastLoginAt,
            provider: profile.provider,
            assignedStoreIds: profile.assignedStoreIds,
            isActive: profile.isActive
        )
    }

    func upsertUserProfile(_ profile: UserProfile) {
        profilesById[profile.id] = UserAccessProfile(
            id: profile.id,
            name: profile.name,
            email: profile.email,
            role: profile.role,
            isActive: profile.isActive,
            provider: profile.provider,
            createdAt: profile.createdAt,
            lastLoginAt: profile.lastLoginAt,
            assignedStoreIds: profile.assignedStoreIds
        )
    }
}

@MainActor
final class UITestUserRepository: UserRepositoryProtocol {
    private let roleProfiles: UITestRoleProfileRepository

    init(roleProfiles: UITestRoleProfileRepository) {
        self.roleProfiles = roleProfiles
    }

    func fetchUser(id: String) async throws -> UserProfile? {
        roleProfiles.userProfile(for: id)
    }

    func upsertUser(_ user: UserProfile) async throws {
        roleProfiles.upsertUserProfile(user)
    }
}

@MainActor
final class UITestStoreRepository: StoreRepositoryProtocol {
    private let authService: AuthServiceProtocol
    private let roleProfiles: UITestRoleProfileRepository

    private var storesById: [String: Store] = [:]
    private var joinCodesByStoreId: [String: String] = [:]
    private var membershipsByEmployeeId: [String: Set<String>] = [:]

    init(authService: AuthServiceProtocol, roleProfiles: UITestRoleProfileRepository) {
        self.authService = authService
        self.roleProfiles = roleProfiles
    }

    func fetchStores(ids: [String]?) async throws -> [Store] {
        if let ids {
            return ids.compactMap { storesById[$0] }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        guard let user = authService.currentUser else {
            return []
        }

        if user.role == .manager {
            return try await fetchManagerStores(managerId: user.id)
        }

        let linkedIds = membershipsByEmployeeId[user.id] ?? []
        return linkedIds.compactMap { storesById[$0] }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        storesById.values
            .filter { $0.managerId == managerId && $0.isActive }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsertStore(_ store: Store) async throws {
        storesById[store.id] = store
        if let code = store.resolvedJoinCode {
            joinCodesByStoreId[store.id] = code
        }
    }

    func deleteStore(id: String) async throws {
        storesById[id] = nil
        joinCodesByStoreId[id] = nil
        for key in membershipsByEmployeeId.keys {
            membershipsByEmployeeId[key]?.remove(id)
        }
    }

    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async throws -> StoreCreationResult {
        guard let manager = authService.currentUser, manager.role == .manager else {
            throw CloudKitClientError.invalidData("Manager access is required to create stores.")
        }
        let storeId = UUID().uuidString
        let code = Self.generateJoinCode()
        let now = Date()
        let store = Store(
            id: storeId,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            isActive: true,
            managerId: manager.id,
            createdAt: now,
            updatedAt: now,
            joinCode: code,
            joinCodeCiphertext: code,
            joinCodeLast4: String(code.suffix(4))
        )
        storesById[storeId] = store
        joinCodesByStoreId[storeId] = code
        return StoreCreationResult(store: store, joinCode: code)
    }

    func rotateStoreCode(storeId: String) async throws -> String {
        guard var store = storesById[storeId] else {
            throw CloudKitClientError.missingRecord("Store not found.")
        }
        let code = Self.generateJoinCode()
        store.joinCode = code
        store.joinCodeCiphertext = code
        store.joinCodeLast4 = String(code.suffix(4))
        store.updatedAt = Date()
        storesById[storeId] = store
        joinCodesByStoreId[storeId] = code
        return code
    }

    func getStoreJoinCode(storeId: String) async throws -> String {
        if let code = joinCodesByStoreId[storeId] {
            return code
        }
        throw CloudKitClientError.missingRecord("Store code not found.")
    }

    func joinStoreByCode(code: String) async throws -> JoinStoreResult {
        guard let user = authService.currentUser else {
            throw CloudKitClientError.signedOut
        }
        guard user.role == .employee else {
            throw CloudKitClientError.invalidData("Only employees can join stores by code.")
        }

        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let entry = joinCodesByStoreId.first(where: { $0.value == normalized }),
              let store = storesById[entry.key] else {
            throw CloudKitClientError.invalidData("Join code not found. Ask your manager for a fresh code.")
        }

        var linked = membershipsByEmployeeId[user.id] ?? []
        let alreadyJoined = linked.contains(store.id)
        linked.insert(store.id)
        membershipsByEmployeeId[user.id] = linked
        roleProfiles.setAssignedStoreIds(Array(linked), for: user.id)

        return JoinStoreResult(
            storeId: store.id,
            storeName: store.name,
            alreadyJoined: alreadyJoined,
            assignedStoreIds: Array(linked).sorted()
        )
    }

    func leaveStore(storeId: String) async throws {
        guard let user = authService.currentUser else {
            throw CloudKitClientError.signedOut
        }
        var linked = membershipsByEmployeeId[user.id] ?? []
        linked.remove(storeId)
        membershipsByEmployeeId[user.id] = linked
        roleProfiles.setAssignedStoreIds(Array(linked), for: user.id)
    }

    private static func generateJoinCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}

@MainActor
final class UITestEmployeeManagementRepository: EmployeeManagementRepositoryProtocol {
    private let roleProfiles: UITestRoleProfileRepository
    private let stores: UITestStoreRepository

    init(roleProfiles: UITestRoleProfileRepository, stores: UITestStoreRepository) {
        self.roleProfiles = roleProfiles
        self.stores = stores
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        try await stores.fetchManagerStores(managerId: managerId)
    }

    func fetchEmployeesForManagerStores(managerStores: [Store]) async throws -> [EmployeeSummary] {
        _ = managerStores
        return []
    }

    func fetchEmployeesForManager(managerId: String) async throws -> [EmployeeSummary] {
        _ = managerId
        return []
    }

    func removeEmployeeFromStore(storeId: String, employeeId: String) async throws {
        _ = storeId
        _ = employeeId
    }

    func removeEmployeeFromAllManagerStores(employeeId: String, managerId: String) async throws {
        _ = employeeId
        _ = managerId
    }

    func setEmployeeStoresForManager(employeeId: String, storeIds: [String]) async throws {
        roleProfiles.setAssignedStoreIds(storeIds, for: employeeId)
    }

    func setEmployeeActive(employeeId: String, isActive: Bool) async throws {
        if !isActive {
            try await roleProfiles.softDeleteAccount(uid: employeeId, role: .employee)
        }
    }
}

private final class UITestCheckInListenerToken: CheckInListenerToken {
    func cancel() {}
}

@MainActor
final class UITestCheckInRepository: CheckInRepositoryProtocol {
    private var sessionsById: [String: CheckIn] = [:]

    @discardableResult
    func listenToTodaysCheckIns(
        filter: CheckInFilter,
        onUpdate: @escaping ([CheckIn]) -> Void,
        onError: @escaping (Error) -> Void
    ) -> CheckInListenerToken {
        _ = onError
        Task {
            let sessions = (try? await fetchTodaysCheckIns(filter: filter)) ?? []
            onUpdate(sessions)
        }
        return UITestCheckInListenerToken()
    }

    func createCheckIn(_ checkIn: CheckIn, checkInPhotoData: Data) async throws {
        _ = checkInPhotoData
        sessionsById[checkIn.id] = checkIn
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
        _ = storeId
        _ = managerId
        _ = checkOutPhotoData
        guard var session = sessionsById[checkinId] else {
            throw CloudKitClientError.missingRecord("Check-in session not found.")
        }
        session.checkOutTime = Date()
        session.checkOutLat = checkoutLat
        session.checkOutLng = checkoutLng
        session.checkOutDistanceMeters = distanceMeters
        session.checkOutAccuracyMeters = accuracyMeters
        session.verifyOutInside = verification.inside
        session.verifyOutDistance1Meters = verification.distance1Meters
        session.verifyOutDistance2Meters = verification.distance2Meters
        session.verifyOutDriftMeters = verification.driftMeters
        session.verifyOutRead1At = verification.read1At
        session.verifyOutRead2At = verification.read2At
        session.verifyOutAccuracy1Meters = verification.read1Accuracy
        session.verifyOutAccuracy2Meters = verification.read2Accuracy
        session.durationSeconds = max(Int((session.checkOutTime ?? Date()).timeIntervalSince(session.checkInTime)), 0)
        sessionsById[checkinId] = session
    }

    func updateCheckIn(_ checkIn: CheckIn) async throws {
        sessionsById[checkIn.id] = checkIn
    }

    func updateCheckInTimes(checkIn: CheckIn, newCheckInTime: Date, newCheckOutTime: Date?) async throws {
        var updated = checkIn
        updated.checkInTime = newCheckInTime
        updated.checkOutTime = newCheckOutTime
        updated.durationSeconds = newCheckOutTime.map { max(Int($0.timeIntervalSince(newCheckInTime)), 0) }
        sessionsById[checkIn.id] = updated
    }

    func deleteCheckIn(checkinId: String, employeeId: String, storeId: String, managerId: String?) async throws {
        _ = employeeId
        _ = storeId
        _ = managerId
        sessionsById[checkinId] = nil
    }

    func deleteCheckIn(checkinId: String, storeId: String, managerId: String) async throws {
        _ = storeId
        _ = managerId
        sessionsById[checkinId] = nil
    }

    func clearAllCheckIns(isManagerScope: Bool, storeId: String?, managerId: String?) async throws {
        _ = isManagerScope
        _ = storeId
        _ = managerId
        sessionsById.removeAll()
    }

    func clearAllCheckIns(storeId: String, managerId: String, limit: Int) async throws {
        _ = managerId
        _ = limit
        sessionsById = sessionsById.filter { $0.value.storeId != storeId }
    }

    func fetchCheckIns(employeeId: String?, limit: Int) async throws -> [CheckIn] {
        let filtered = sessionsById.values.filter { session in
            guard let employeeId else { return true }
            return session.employeeId == employeeId
        }
        return Array(filtered.sorted { $0.checkInTime > $1.checkInTime }.prefix(limit))
    }

    func fetchEmployeeCheckIns(employeeId: String, limit: Int) async throws -> [CheckIn] {
        let filtered = sessionsById.values.filter { $0.employeeId == employeeId }
        return Array(filtered.sorted { $0.checkInTime > $1.checkInTime }.prefix(limit))
    }

    func fetchManagerStoreCheckIns(managerId: String, storeId: String, fromDate: Date, toDate: Date, employeeId: String?, limit: Int) async throws -> [CheckIn] {
        _ = managerId
        let filtered = sessionsById.values.filter { session in
            guard session.storeId == storeId else { return false }
            guard session.checkInTime >= fromDate && session.checkInTime < toDate else { return false }
            if let employeeId {
                return session.employeeId == employeeId
            }
            return true
        }
        return Array(filtered.sorted { $0.checkInTime > $1.checkInTime }.prefix(limit))
    }

    func fetchTodaysCheckIns(filter: CheckInFilter) async throws -> [CheckIn] {
        let start = Calendar.current.startOfDay(for: filter.date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? filter.date
        return sessionsById.values.filter { session in
            guard session.checkInTime >= start && session.checkInTime < end else { return false }
            if let storeId = filter.storeId, session.storeId != storeId {
                return false
            }
            if let status = filter.status, session.status != status {
                return false
            }
            return true
        }
        .sorted { $0.checkInTime > $1.checkInTime }
    }
}
#endif
