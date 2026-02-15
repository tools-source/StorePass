import FirebaseFirestore
import Foundation

protocol UserRepositoryProtocol {
    func fetchUser(id: String) async throws -> UserProfile?
    func upsertUser(_ user: UserProfile) async throws
    func fetchEmployees() async throws -> [UserProfile]
    func fetchManagersCount() async throws -> Int
}

final class FirestoreUserRepository: UserRepositoryProtocol {
    private let db = Firestore.firestore()

    func fetchUser(id: String) async throws -> UserProfile? {
        let doc = try await db.collection("users").document(id).getDocument()
        guard let data = doc.data() else { return nil }
        return try decodeUser(id: doc.documentID, data: data)
    }

    func upsertUser(_ user: UserProfile) async throws {
        try await db.collection("users").document(user.id).setData(encode(user: user), merge: true)
    }

    func fetchEmployees() async throws -> [UserProfile] {
        let snap = try await db.collection("users")
            .whereField("role", isEqualTo: UserRole.employee.rawValue)
            .order(by: "name")
            .getDocuments()
        return try snap.documents.compactMap { try decodeUser(id: $0.documentID, data: $0.data()) }
    }

    func fetchManagersCount() async throws -> Int {
        let snap = try await db.collection("users").whereField("role", isEqualTo: UserRole.manager.rawValue).limit(to: 1).getDocuments()
        return snap.documents.count
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
}
