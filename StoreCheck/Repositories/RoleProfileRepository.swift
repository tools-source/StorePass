import FirebaseFirestore
import Foundation

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

protocol RoleProfileRepositoryProtocol {
    func fetchManagerProfile(uid: String) async throws -> ManagerProfile?
    func fetchEmployeeProfile(uid: String) async throws -> EmployeeProfile?
    func upsertManagerProfile(uid: String, name: String, email: String?) async throws
    func upsertEmployeeProfile(uid: String, name: String, email: String?) async throws
    func deleteManagerProfile(uid: String) async throws
    func deleteEmployeeProfile(uid: String) async throws
}

final class FirestoreRoleProfileRepository: RoleProfileRepositoryProtocol {
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreRoleProfileRepository.db")
        return Firestore.firestore()
    }

    func fetchManagerProfile(uid: String) async throws -> ManagerProfile? {
        let doc = try await db.collection("managers").document(uid).getDocument()
        guard let data = doc.data() else { return nil }
        return ManagerProfile(
            id: uid,
            name: data["name"] as? String ?? "StorePass User",
            email: data["email"] as? String,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            lastLoginAt: (data["lastLoginAt"] as? Timestamp)?.dateValue() ?? Date(),
            isActive: data["isActive"] as? Bool ?? true
        )
    }

    func fetchEmployeeProfile(uid: String) async throws -> EmployeeProfile? {
        let doc = try await db.collection("employees").document(uid).getDocument()
        guard let data = doc.data() else { return nil }
        return EmployeeProfile(
            id: uid,
            name: data["name"] as? String ?? "StorePass User",
            email: data["email"] as? String,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            lastLoginAt: (data["lastLoginAt"] as? Timestamp)?.dateValue() ?? Date(),
            isActive: data["isActive"] as? Bool ?? true,
            assignedStoreIds: data["assignedStoreIds"] as? [String] ?? []
        )
    }

    func upsertManagerProfile(uid: String, name: String, email: String?) async throws {
        let now = Date()
        try await db.collection("managers").document(uid).setData([
            "name": name,
            "email": email as Any,
            "createdAt": FieldValue.serverTimestamp(),
            "lastLoginAt": Timestamp(date: now),
            "isActive": true
        ], merge: true)
    }

    func upsertEmployeeProfile(uid: String, name: String, email: String?) async throws {
        let now = Date()
        try await db.collection("employees").document(uid).setData([
            "name": name,
            "email": email as Any,
            "createdAt": FieldValue.serverTimestamp(),
            "lastLoginAt": Timestamp(date: now),
            "isActive": true,
            "assignedStoreIds": FieldValue.arrayUnion([])
        ], merge: true)
    }

    func deleteManagerProfile(uid: String) async throws {
        try await db.collection("managers").document(uid).delete()
    }

    func deleteEmployeeProfile(uid: String) async throws {
        try await db.collection("employees").document(uid).delete()
    }
}
