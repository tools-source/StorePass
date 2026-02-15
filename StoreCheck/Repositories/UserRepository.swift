import FirebaseFirestore
import Foundation

protocol UserRepositoryProtocol {
    func fetchUser(id: String) async throws -> UserProfile?
    func upsertUser(_ user: UserProfile) async throws
    func fetchEmployees() async throws -> [UserProfile]
}

final class FirestoreUserRepository: UserRepositoryProtocol {
    private let db = Firestore.firestore()

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

    private func decodeUser(id: String, data: [String: Any]) throws -> UserProfile {
        UserProfile(
            id: id,
            name: data["name"] as? String ?? "StorePass User",
            email: data["email"] as? String,
            role: UserRole(rawValue: data["role"] as? String ?? "employee") ?? .employee,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            lastLoginAt: (data["lastLoginAt"] as? Timestamp)?.dateValue() ?? Date(),
            provider: data["provider"] as? String ?? "unknown",
            assignedStoreIds: data["assignedStoreIds"] as? [String] ?? [],
            isActive: data["isActive"] as? Bool ?? true
        )
    }

    private func encode(user: UserProfile) -> [String: Any] {
        [
            "name": user.name,
            "email": user.email as Any,
            "role": user.role.rawValue,
            "createdAt": Timestamp(date: user.createdAt),
            "lastLoginAt": Timestamp(date: user.lastLoginAt),
            "provider": user.provider,
            "assignedStoreIds": user.assignedStoreIds,
            "isActive": user.isActive
        ]
    }

    private func mapFirestoreError(_ error: Error) -> Error {
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
