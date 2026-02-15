import FirebaseFirestore
import FirebaseFirestoreSwift
import Foundation

protocol UserRepositoryProtocol {
    func fetchUser(id: String) async throws -> UserProfile
    func upsertUser(_ user: UserProfile) async throws
    func fetchEmployees() async throws -> [UserProfile]
}

final class FirestoreUserRepository: UserRepositoryProtocol {
    private let db = Firestore.firestore()

    func fetchUser(id: String) async throws -> UserProfile {
        try await db.collection("users").document(id).getDocument(as: UserProfile.self)
    }

    func upsertUser(_ user: UserProfile) async throws {
        try db.collection("users").document(user.id).setData(from: user)
    }

    func fetchEmployees() async throws -> [UserProfile] {
        let snap = try await db.collection("users").whereField("role", isEqualTo: UserRole.employee.rawValue).getDocuments()
        return try snap.documents.map { try $0.data(as: UserProfile.self) }
    }
}
