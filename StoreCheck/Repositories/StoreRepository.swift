import FirebaseFirestore
import Foundation

protocol StoreRepositoryProtocol {
    func fetchStores(ids: [String]?) async throws -> [Store]
    func upsertStore(_ store: Store) async throws
    func deleteStore(id: String) async throws
}

final class FirestoreStoreRepository: StoreRepositoryProtocol {
    private var db: Firestore { Firestore.firestore() }

    func fetchStores(ids: [String]? = nil) async throws -> [Store] {
        do {
            let snapshot: QuerySnapshot
            if let ids, !ids.isEmpty {
                snapshot = try await db.collection("stores").whereField(FieldPath.documentID(), in: ids).getDocuments()
            } else {
                snapshot = try await db.collection("stores").order(by: "name").getDocuments()
            }
            return snapshot.documents.compactMap(decodeStore)
        } catch {
            throw mapFirestoreError(error)
        }
    }

    func upsertStore(_ store: Store) async throws {
        let data: [String: Any] = [
            "name": store.name,
            "address": store.address,
            "lat": store.lat,
            "lng": store.lng,
            "radiusMeters": store.radiusMeters,
            "isActive": store.isActive
        ]

        do {
            try await db.collection("stores").document(store.id).setData(data, merge: true)
        } catch {
            throw mapFirestoreError(error)
        }
    }

    func deleteStore(id: String) async throws {
        do {
            try await db.collection("stores").document(id).delete()
        } catch {
            throw mapFirestoreError(error)
        }
    }

    private func decodeStore(document: QueryDocumentSnapshot) -> Store? {
        let data = document.data()
        return Store(
            id: document.documentID,
            name: data["name"] as? String ?? "Unnamed Store",
            address: data["address"] as? String ?? "",
            lat: data["lat"] as? Double ?? 0,
            lng: data["lng"] as? Double ?? 0,
            radiusMeters: data["radiusMeters"] as? Int ?? 150,
            isActive: data["isActive"] as? Bool ?? true
        )
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
