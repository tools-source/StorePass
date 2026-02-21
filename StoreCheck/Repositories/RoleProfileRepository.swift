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

struct UserAccessProfile {
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

protocol RoleProfileRepositoryProtocol {
    func ensureUserProfile(uid: String, name: String, email: String?, provider: String) async throws -> UserAccessProfile
    func fetchUserProfile(uid: String) async throws -> UserAccessProfile?
}

final class FirestoreRoleProfileRepository: RoleProfileRepositoryProtocol {
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreRoleProfileRepository.db")
        return Firestore.firestore()
    }

    func ensureUserProfile(uid: String, name: String, email: String?, provider: String) async throws -> UserAccessProfile {
        let userRef = db.collection("users").document(uid)
        let userDoc = try await userRef.getDocument()

        if userDoc.exists {
            try await userRef.setData([
                "name": name,
                "email": email as Any,
                "provider": provider,
                "lastLoginAt": FieldValue.serverTimestamp()
            ], merge: true)
        } else {
            try await userRef.setData([
                "name": name,
                "email": email as Any,
                "role": UserRole.employee.rawValue,
                "isActive": true,
                "provider": provider,
                "createdAt": FieldValue.serverTimestamp(),
                "lastLoginAt": FieldValue.serverTimestamp(),
                "assignedStoreIds": []
            ], merge: true)
        }

        guard let profile = try await fetchUserProfile(uid: uid) else {
            throw NSError(domain: "StorePass", code: 3001, userInfo: [NSLocalizedDescriptionKey: "Unable to load profile."])
        }
        return profile
    }

    func fetchUserProfile(uid: String) async throws -> UserAccessProfile? {
        let doc = try await db.collection("users").document(uid).getDocument()
        guard let data = doc.data() else { return nil }
        return UserAccessProfile(
            id: uid,
            name: data["name"] as? String ?? "StorePass User",
            email: data["email"] as? String,
            role: UserRole(rawValue: (data["role"] as? String ?? UserRole.employee.rawValue).lowercased()) ?? .employee,
            isActive: data["isActive"] as? Bool ?? true,
            provider: data["provider"] as? String ?? "unknown",
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            lastLoginAt: (data["lastLoginAt"] as? Timestamp)?.dateValue() ?? Date(),
            assignedStoreIds: data["assignedStoreIds"] as? [String] ?? []
        )
    }
}
