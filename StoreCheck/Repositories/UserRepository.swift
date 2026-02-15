import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

protocol UserRepositoryProtocol {
    func fetchUser(id: String) async throws -> UserProfile?
    func upsertUser(_ user: UserProfile) async throws
    func fetchEmployees() async throws -> [UserProfile]
}

protocol EmployeeManagementRepositoryProtocol {
    func createEmployeeUnderManager(managerId: String, name: String, email: String, tempPassword: String, storeIds: [String]) async throws
    func fetchEmployeesForManager(managerId: String) async throws -> [EmployeeSummary]
    func updateEmployeeStores(managerId: String, employeeId: String, storeIds: [String]) async throws
    func setEmployeeActive(managerId: String, employeeId: String, isActive: Bool) async throws
    func unlinkEmployee(managerId: String, employeeId: String) async throws
}

final class FirestoreUserRepository: UserRepositoryProtocol {
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreUserRepository.db")
        return Firestore.firestore()
    }

    func fetchUser(id: String) async throws -> UserProfile? {
        do {
            let doc = try await db.collection("users").document(id).getDocument()
            guard let data = doc.data() else { return nil }
            return try decodeUser(id: doc.documentID, data: data)
        } catch {
            throw mapFirestoreError(error)
        }
    }

    func upsertUser(_ user: UserProfile) async throws {
        do {
            try await db.collection("users").document(user.id).setData(encode(user: user), merge: true)
        } catch {
            throw mapFirestoreError(error)
        }
    }

    func fetchEmployees() async throws -> [UserProfile] {
        do {
            let snap = try await db.collection("users")
                .whereField("role", isEqualTo: UserRole.employee.rawValue)
                .order(by: "name")
                .getDocuments()
            return try snap.documents.compactMap { try decodeUser(id: $0.documentID, data: $0.data()) }
        } catch {
            throw mapFirestoreError(error)
        }
    }

    fileprivate func decodeUser(id: String, data: [String: Any]) throws -> UserProfile {
        UserProfile(
            id: id,
            name: data["name"] as? String ?? "StorePass User",
            email: data["email"] as? String,
            role: UserRole(rawValue: data["role"] as? String ?? "employee") ?? .employee,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            lastLoginAt: (data["lastLoginAt"] as? Timestamp)?.dateValue() ?? Date(),
            provider: data["provider"] as? String ?? "unknown",
            assignedStoreIds: data["assignedStoreIds"] as? [String] ?? [],
            isActive: data["isActive"] as? Bool ?? true,
            createdByManagerId: data["createdByManagerId"] as? String
        )
    }

    fileprivate func encode(user: UserProfile) -> [String: Any] {
        [
            "name": user.name,
            "email": user.email as Any,
            "role": user.role.rawValue,
            "createdAt": Timestamp(date: user.createdAt),
            "lastLoginAt": Timestamp(date: user.lastLoginAt),
            "provider": user.provider,
            "assignedStoreIds": user.assignedStoreIds,
            "isActive": user.isActive,
            "createdByManagerId": user.createdByManagerId as Any
        ]
    }

    fileprivate func mapFirestoreError(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              nsError.code == FirestoreErrorCode.permissionDenied.rawValue else {
            return error
        }

        return NSError(
            domain: "StorePass",
            code: nsError.code,
            userInfo: [NSLocalizedDescriptionKey: "You don't have permission for this action."]
        )
    }
}

final class FirestoreEmployeeManagementRepository: EmployeeManagementRepositoryProtocol {
    private let userRepository = FirestoreUserRepository()

    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreEmployeeManagementRepository.db")
        return Firestore.firestore()
    }

    func createEmployeeUnderManager(managerId: String, name: String, email: String, tempPassword: String, storeIds: [String]) async throws {
        let payload: [String: Any] = [
            "managerId": managerId,
            "name": name,
            "email": email,
            "tempPassword": tempPassword,
            "storeIds": storeIds
        ]

        _ = try await callFirebaseFunction(name: "createEmployeeUnderManager", payload: payload)
    }

    func fetchEmployeesForManager(managerId: String) async throws -> [EmployeeSummary] {
        let linkCollection = db.collection("managers").document(managerId).collection("employees")
        let linkSnapshot = try await linkCollection.order(by: "createdAt", descending: true).getDocuments()

        let links: [EmployeeLink] = linkSnapshot.documents.map { doc in
            let data = doc.data()
            return EmployeeLink(
                id: doc.documentID,
                employeeUserId: data["employeeUserId"] as? String ?? doc.documentID,
                stores: data["stores"] as? [String] ?? [],
                isActive: data["isActive"] as? Bool ?? true,
                createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date.distantPast
            )
        }

        return try await withThrowingTaskGroup(of: EmployeeSummary?.self) { group in
            for link in links {
                group.addTask {
                    guard let profile = try await self.userRepository.fetchUser(id: link.employeeUserId) else {
                        return nil
                    }

                    return EmployeeSummary(
                        id: link.id,
                        name: profile.name,
                        email: profile.email,
                        assignedStoreIds: profile.assignedStoreIds,
                        linkedStoreIds: link.stores,
                        isActive: profile.isActive,
                        createdAt: link.createdAt,
                        employeeUserId: link.employeeUserId
                    )
                }
            }

            var summaries: [EmployeeSummary] = []
            for try await summary in group {
                if let summary {
                    summaries.append(summary)
                }
            }
            return summaries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func updateEmployeeStores(managerId: String, employeeId: String, storeIds: [String]) async throws {
        let batch = db.batch()
        let userRef = db.collection("users").document(employeeId)
        let linkRef = db.collection("managers").document(managerId).collection("employees").document(employeeId)

        batch.updateData(["assignedStoreIds": storeIds], forDocument: userRef)
        batch.updateData(["stores": storeIds], forDocument: linkRef)

        try await batch.commit()
    }

    func setEmployeeActive(managerId: String, employeeId: String, isActive: Bool) async throws {
        let batch = db.batch()
        let userRef = db.collection("users").document(employeeId)
        let linkRef = db.collection("managers").document(managerId).collection("employees").document(employeeId)

        batch.updateData(["isActive": isActive], forDocument: userRef)
        batch.updateData(["isActive": isActive], forDocument: linkRef)

        try await batch.commit()
    }

    func unlinkEmployee(managerId: String, employeeId: String) async throws {
        try await db.collection("managers").document(managerId).collection("employees").document(employeeId).delete()
    }

    private func callFirebaseFunction(name: String, payload: [String: Any]) async throws -> [String: Any] {
        guard let user = Auth.auth().currentUser else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in as a manager."])
        }

        guard let projectID = FirebaseApp.app()?.options.projectID else {
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
