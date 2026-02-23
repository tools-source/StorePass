import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation

// MARK: - Protocols

protocol UserRepositoryProtocol {
    func fetchUser(id: String) async throws -> UserProfile?
    func upsertUser(_ user: UserProfile) async throws
}

protocol EmployeeManagementRepositoryProtocol {
    func fetchManagerStores(managerId: String) async throws -> [Store]

    // ✅ NEW: index-free employees fetch using store list
    func fetchEmployeesForManagerStores(managerStores: [Store]) async throws -> [EmployeeSummary]

    // Keep existing API (optional legacy)
    func fetchEmployeesForManager(managerId: String) async throws -> [EmployeeSummary]

    func removeEmployeeFromStore(storeId: String, employeeId: String) async throws
    func removeEmployeeFromAllManagerStores(employeeId: String, managerId: String) async throws
    func setEmployeeStoresForManager(employeeId: String, storeIds: [String]) async throws
    func setEmployeeActive(employeeId: String, isActive: Bool) async throws
}



enum CloudFunctionClientError: LocalizedError {
    case unexpectedServerResponse(rawPayload: Any?)

    var errorDescription: String? {
        switch self {
        case .unexpectedServerResponse:
            return "Unexpected server response."
        }
    }
}

final class CloudFunctionsService {
    private let functions = Functions.functions(region: "us-central1")
    private let region = "us-central1"

    func leaveStore(storeId: String) async throws -> Bool {
        return try await callExpectingOK(name: "leaveStore", payload: ["storeId": storeId])
    }

    func removeEmployeeFromStore(storeId: String, employeeId: String) async throws -> Bool {
        return try await invokeRemoveEmployeeFromStore(storeId: storeId, employeeId: employeeId)
    }

    func deleteManagerAccount() async throws -> Bool {
        return try await callExpectingOK(name: "deleteManagerAccount", payload: [:])
    }

    private func invokeRemoveEmployeeFromStore(storeId: String, employeeId: String) async throws -> Bool {
        return try await callExpectingOK(name: "removeEmployeeFromStore", payload: ["storeId": storeId, "employeeId": employeeId])
    }

    private func callExpectingOK(name: String, payload: [String: Any]) async throws -> Bool {
        do {
            print("[Functions][CALL] name=\(name) region=\(region) payload=\(payload)")
            let callable = functions.httpsCallable(name)
            let result = try await callable.call(payload)
            print("[Functions][OK] name=\(name) result=\(String(describing: result.data))")

            guard let data = result.data as? [String: Any],
                  let ok = data["ok"] as? Bool else {
                throw CloudFunctionClientError.unexpectedServerResponse(rawPayload: result.data)
            }
            guard ok else {
                throw CloudFunctionClientError.unexpectedServerResponse(rawPayload: data)
            }
            return ok
        } catch {
            let ns = error as NSError
            print("[Functions][FAIL] domain=\(ns.domain) code=\(ns.code) message=\(ns.localizedDescription) userInfo=\(ns.userInfo)")
            throw mapError(error)
        }
    }

    private func mapError(_ error: Error) -> NSError {
        if case CloudFunctionClientError.unexpectedServerResponse = error {
            return NSError(domain: "StorePass", code: 4004, userInfo: [NSLocalizedDescriptionKey: "Unexpected server response."])
        }

        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain,
           let code = FunctionsErrorCode(rawValue: nsError.code) {
            let message: String
            switch code {
            case .permissionDenied:
                message = "You don’t have permission."
            case .failedPrecondition:
                message = "This action can’t be completed right now."
            case .notFound:
                message = "Function may be missing: check callable name and region (us-central1)."
            case .internal:
                message = "Something went wrong. Try again."
            default:
                message = nsError.localizedDescription
            }
            return NSError(
                domain: nsError.domain,
                code: nsError.code,
                userInfo: [NSLocalizedDescriptionKey: "\(message) [region=\(region) code=\(code)]"]
            )
        }
        return nsError
    }
}

// MARK: - User Repo

final class FirestoreUserRepository: UserRepositoryProtocol {
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreUserRepository.db")
        return Firestore.firestore()
    }

    func fetchUser(id: String) async throws -> UserProfile? {
        do {
            let doc = try await db.collection("users").document(id).getDocument()
            guard let data = doc.data() else { return nil }
            return decodeUser(id: doc.documentID, data: data)
        } catch {
            FirestorePermissionLogger.log(operation: "getDocument", path: "users/\(id)", error: error)
            throw error
        }
    }

    func upsertUser(_ user: UserProfile) async throws {
        let payload = encode(user: user)
        do {
            try await db.collection("users").document(user.id).setData(payload, merge: true)
        } catch {
            FirestorePermissionLogger.log(operation: "setData", path: "users/\(user.id)", error: error)
            throw error
        }
    }

    fileprivate func decodeUser(id: String, data: [String: Any]) -> UserProfile {
        UserProfile(
            id: id,
            name: data["name"] as? String ?? "StorePass User",
            email: data["email"] as? String,
            role: UserRole(rawValue: (data["role"] as? String ?? UserRole.employee.rawValue).lowercased()) ?? .employee,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            lastLoginAt: (data["lastLoginAt"] as? Timestamp)?.dateValue() ?? Date(),
            provider: data["provider"] as? String ?? "unknown",
            assignedStoreIds: data["assignedStoreIds"] as? [String] ?? [],
            isActive: data["isActive"] as? Bool ?? true
        )
    }

    fileprivate func encode(user: UserProfile) -> [String: Any] {
        return [
            "name": user.name,
            "email": user.email as Any,
            "lastLoginAt": Timestamp(date: user.lastLoginAt),
            "provider": user.provider,
            "assignedStoreIds": user.assignedStoreIds
        ]
    }
}

// MARK: - Employee Management Repo

final class FirestoreEmployeeManagementRepository: EmployeeManagementRepositoryProtocol {
    private let cloudFunctions = CloudFunctionsService()
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreEmployeeManagementRepository.db")
        return Firestore.firestore()
    }

    private var auth: Auth {
        FirebaseBootstrap.assertConfigured(context: "FirestoreEmployeeManagementRepository.auth")
        return Auth.auth()
    }

    private var firebaseApp: FirebaseApp {
        FirebaseBootstrap.assertConfigured(context: "FirestoreEmployeeManagementRepository.firebaseApp")
        guard let app = FirebaseApp.app() else {
            fatalError("Firebase app is unexpectedly unavailable.")
        }
        return app
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        let snapshot = try await db.collection("managerStores")
            .document(managerId)
            .collection("stores")
            .whereField("isActive", isEqualTo: true)
            .getDocuments()

        let stores = snapshot.documents.map(decodeStore)
        return stores.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Debugging notes:
    // - Expected query shape: stores/{storeId}/members ordered by joinedAt desc when available.
    // - No composite index is required for subcollection-only orderBy(joinedAt).
    func fetchEmployeesForManagerStores(managerStores: [Store]) async throws -> [EmployeeSummary] {
        if managerStores.isEmpty { return [] }

        let managerUid = auth.currentUser?.uid ?? "nil"
        let storesById = Dictionary(uniqueKeysWithValues: managerStores.map { ($0.id, $0) })

        // employeeId -> aggregate membership metadata
        var storeIdsByEmployee: [String: Set<String>] = [:]
        var inactiveMemberByEmployee: [String: Bool] = [:]
        var membershipNameByEmployee: [String: String] = [:]
        var membershipEmailByEmployee: [String: String] = [:]

        for store in managerStores {
            let storeId = store.id
            let membersPath = "stores/\(storeId)/members"
            print("[Employees][QUERY] managerUid=\(managerUid) storeId=\(storeId) path=\(membersPath) orderBy=joinedAt DESC")

            var membersSnap: QuerySnapshot
            do {
                membersSnap = try await db.collection("stores")
                    .document(storeId)
                    .collection("members")
                    .order(by: "joinedAt", descending: true)
                    .getDocuments()
            } catch {
                let nsError = error as NSError
                if nsError.domain == FirestoreErrorDomain,
                   let code = FirestoreErrorCode.Code(rawValue: nsError.code),
                   code == .failedPrecondition {
                    print("[Employees][QUERY] managerUid=\(managerUid) storeId=\(storeId) missingIndexOnJoinedAt=true fallback=noOrder")
                    membersSnap = try await db.collection("stores")
                        .document(storeId)
                        .collection("members")
                        .getDocuments()
                } else {
                    FirestorePermissionLogger.log(operation: "getDocuments", path: membersPath, error: error)
                    throw error
                }
            }

            print("[Employees][QUERY] managerUid=\(managerUid) storeId=\(storeId) docsCount=\(membersSnap.documents.count)")

            if membersSnap.documents.isEmpty {
                let ownsStore = store.managerId == auth.currentUser?.uid
                print("[Employees][QUERY] emptyMembers managerUid=\(managerUid) storeId=\(storeId) managerOwnsStore=\(ownsStore)")
            }

            for doc in membersSnap.documents {
                let data = doc.data()
                let employeeId = (data["userId"] as? String) ?? doc.documentID
                let keys = data.keys.sorted().joined(separator: ",")
                let hasJoinedAt = data["joinedAt"] != nil
                print("[Employees][MEMBERSHIP] storeId=\(storeId) employeeId=\(employeeId) keys=[\(keys)] hasJoinedAt=\(hasJoinedAt)")

                // keep role filtering permissive for legacy memberships that omit role
                let role = (data["role"] as? String)?.lowercased()
                if let role, role != UserRole.employee.rawValue {
                    continue
                }

                storeIdsByEmployee[employeeId, default: []].insert(storeId)

                if let memberActive = data["isActive"] as? Bool, memberActive == false {
                    inactiveMemberByEmployee[employeeId] = true
                }

                if membershipNameByEmployee[employeeId] == nil {
                    if let name = data["employeeName"] as? String, !name.isEmpty {
                        membershipNameByEmployee[employeeId] = name
                    } else if let name = data["displayName"] as? String, !name.isEmpty {
                        membershipNameByEmployee[employeeId] = name
                    } else if let name = data["name"] as? String, !name.isEmpty {
                        membershipNameByEmployee[employeeId] = name
                    }
                }

                if membershipEmailByEmployee[employeeId] == nil {
                    if let email = data["employeeEmail"] as? String, !email.isEmpty {
                        membershipEmailByEmployee[employeeId] = email
                    } else if let email = data["email"] as? String, !email.isEmpty {
                        membershipEmailByEmployee[employeeId] = email
                    } else if data.keys.contains("employeeEmail") || data.keys.contains("email") {
                        membershipEmailByEmployee[employeeId] = ""
                    }
                }
            }
        }

        if storeIdsByEmployee.isEmpty {
            print("[Employees][QUERY] managerUid=\(managerUid) result=emptyAcrossStores storeCount=\(managerStores.count)")
            return []
        }

        let employeeIds = Array(storeIdsByEmployee.keys)

        var rows: [EmployeeSummary] = []
        rows.reserveCapacity(employeeIds.count)

        for employeeId in employeeIds {
            let storeIdsForEmployee = Array(storeIdsByEmployee[employeeId] ?? []).sorted()
            let storeNames = storeIdsForEmployee.compactMap { storesById[$0]?.name }
            let membershipName = membershipNameByEmployee[employeeId]
            let membershipEmail = membershipEmailByEmployee[employeeId]
            let resolvedName = membershipName
                ?? "Employee \(employeeId.prefix(6))"
            let resolvedEmail = (membershipEmail?.isEmpty == false) ? membershipEmail : nil

            if membershipName == nil || membershipEmail == nil {
                print("[Employees][MEMBERSHIP] missingFields employeeId=\(employeeId) missingName=\(membershipName == nil) missingEmail=\(membershipEmail == nil)")
            }

            rows.append(
                EmployeeSummary(
                    id: employeeId,
                    name: resolvedName,
                    email: resolvedEmail,
                    storeIds: storeIdsForEmployee,
                    storeNames: storeNames,
                    userIsActive: !(inactiveMemberByEmployee[employeeId] ?? false),
                    hasInactiveMembership: inactiveMemberByEmployee[employeeId] ?? false
                )
            )
        }

        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Legacy method kept for compatibility (calls the new one)
    func fetchEmployeesForManager(managerId: String) async throws -> [EmployeeSummary] {
        let stores = try await fetchManagerStores(managerId: managerId)
        return try await fetchEmployeesForManagerStores(managerStores: stores)
    }

    func removeEmployeeFromStore(storeId: String, employeeId: String) async throws {
        _ = try await cloudFunctions.removeEmployeeFromStore(storeId: storeId, employeeId: employeeId)
    }

    func removeEmployeeFromAllManagerStores(employeeId: String, managerId: String) async throws {
        _ = try await callable(name: "removeEmployeeFromAllManagerStores", payload: ["employeeId": employeeId, "managerId": managerId])
    }

    func setEmployeeStoresForManager(employeeId: String, storeIds: [String]) async throws {
        _ = try await callable(name: "setEmployeeStoresForManager", payload: ["employeeId": employeeId, "storeIds": storeIds])
    }

    func setEmployeeActive(employeeId: String, isActive: Bool) async throws {
        _ = try await callable(name: "setEmployeeActive", payload: ["employeeId": employeeId, "isActive": isActive])
    }

    private func decodeStore(_ document: QueryDocumentSnapshot) -> Store {
        let data = document.data()

        func asDouble(_ keys: [String]) -> Double? {
            for key in keys {
                if let value = data[key] as? Double { return value }
                if let value = data[key] as? Int { return Double(value) }
                if let value = data[key] as? NSNumber { return value.doubleValue }
            }
            return nil
        }

        func asInt(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = data[key] as? Int { return value }
                if let value = data[key] as? Double { return Int(value) }
                if let value = data[key] as? NSNumber { return value.intValue }
            }
            return nil
        }

        return Store(
            id: document.documentID,
            name: data["name"] as? String ?? "Store",
            address: data["address"] as? String ?? "",
            latitude: asDouble(["latitude", "lat"]) ?? 0,
            longitude: asDouble(["longitude", "lng", "lon"]) ?? 0,
            radiusMeters: asInt(["radiusMeters", "radius"]) ?? 150,
            isActive: data["isActive"] as? Bool ?? true,
            managerId: data["managerId"] as? String,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue(),
            joinCodeLast4: data["joinCodeLast4"] as? String
        )
    }

    private func callable(name: String, payload: [String: Any]) async throws -> [String: Any] {
        FirebaseBootstrap.assertConfigured(context: "FirestoreEmployeeManagementRepository.callable")

        guard let user = auth.currentUser else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
        }
        let projectID = firebaseApp.options.projectID ?? ""
        guard !projectID.isEmpty else {
            throw NSError(domain: "StorePass", code: 4002, userInfo: [NSLocalizedDescriptionKey: "Firebase project is not configured correctly."])
        }

        let token = try await user.getIDToken()
        guard let url = URL(string: "https://us-central1-\(projectID).cloudfunctions.net/\(name)") else {
            throw NSError(domain: "StorePass", code: 4003, userInfo: [NSLocalizedDescriptionKey: "Unable to build backend URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": payload])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "StorePass", code: 4004, userInfo: [NSLocalizedDescriptionKey: "Unexpected backend response."])
        }

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let errorObj = object["error"] as? [String: Any] {
            let message = errorObj["message"] as? String ?? "Backend error"
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Backend request failed."])
        }
        return object["result"] as? [String: Any] ?? object
    }
}

// MARK: - Helpers

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var result: [[Element]] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + size, count)
            result.append(Array(self[i..<end]))
            i = end
        }
        return result
    }
}
