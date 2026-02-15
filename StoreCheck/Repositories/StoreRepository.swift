import FirebaseFirestore
import FirebaseFirestore
import Foundation

protocol StoreRepositoryProtocol {
    func fetchStores(ids: [String]?) async throws -> [Store]
    func upsertStore(_ store: Store) async throws
    func deleteStore(id: String) async throws
}

final class FirestoreStoreRepository: StoreRepositoryProtocol {
    private let db = Firestore.firestore()

    func fetchStores(ids: [String]? = nil) async throws -> [Store] {
        if let ids, !ids.isEmpty {
            let snap = try await db.collection("stores").whereField(FieldPath.documentID(), in: ids).getDocuments()
            return try snap.documents.map { try $0.data(as: Store.self) }
        }
        let snap = try await db.collection("stores").getDocuments()
        return try snap.documents.map { try $0.data(as: Store.self) }
    }

    func upsertStore(_ store: Store) async throws {
        try db.collection("stores").document(store.id).setData(from: store)
    }

    func deleteStore(id: String) async throws {
        try await db.collection("stores").document(id).delete()
    }
}
