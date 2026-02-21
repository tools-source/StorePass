import Foundation
import FirebaseFirestore
import FirebaseAuth

final class FirestoreStoreRepository: StoreRepositoryProtocol {

    private let db = Firestore.firestore()

    // MARK: - Fetch

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        let snapshot = try await db.collection("stores")
            .whereField("ownerId", isEqualTo: managerId)
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            try? doc.data(as: Store.self)
        }
    }

    func fetchStores(ids: [String]?) async throws -> [Store] {
        guard let ids, !ids.isEmpty else {
            let snapshot = try await db.collection("stores").getDocuments()
            return snapshot.documents.compactMap { doc in
                try? doc.data(as: Store.self)
            }
        }

        // Firestore "in" queries max 10 ids (if you ever pass more, split them)
        let snapshot = try await db.collection("stores")
            .whereField(FieldPath.documentID(), in: ids)
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            try? doc.data(as: Store.self)
        }
    }

    // MARK: - Create (MUST match protocol exactly)

    func createStore(
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Int
    ) async throws -> (store: Store, joinCode: String) {

        guard let uid = Auth.auth().currentUser?.uid else {
            throw StoreRepoError.notAuthenticated
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StoreRepoError.invalidName
        }

        let storeRef = db.collection("stores").document()
        let joinCode = Self.generateJoinCode()

        let payload: [String: Any] = [
            "name": trimmedName,
            "address": address,
            "ownerId": uid,
            "joinCode": joinCode,
            "location": GeoPoint(latitude: latitude, longitude: longitude),
            "radiusMeters": radiusMeters,
            "createdAt": FieldValue.serverTimestamp()
        ]

        do {
            try await storeRef.setData(payload)

            // Build Store model locally (adjust fields if your Store model differs)
            let store = Store(
                id: storeRef.documentID,
                name: trimmedName,
                address: address,
                ownerId: uid,
                latitude: latitude,
                longitude: longitude,
                radiusMeters: radiusMeters
            )

            return (store: store, joinCode: joinCode)
        } catch {
            logFirestoreCreateError(error, path: storeRef.path)
            throw wrapCreateError(error, path: storeRef.path)
        }
    }

    // MARK: - Update

    func upsertStore(_ store: Store) async throws {
        let ref = db.collection("stores").document(store.id)

        let payload: [String: Any] = [
            "name": store.name,
            "address": store.address,
            "ownerId": store.ownerId,
            "location": GeoPoint(latitude: store.latitude, longitude: store.longitude),
            "radiusMeters": store.radiusMeters
        ]

        try await ref.setData(payload, merge: true)
    }

    // MARK: - Delete

    func deleteStore(id: String) async throws {
        try await db.collection("stores").document(id).delete()
    }

    // MARK: - Join Code

    func rotateStoreCode(storeId: String) async throws -> String {
        let newCode = Self.generateJoinCode()
        try await db.collection("stores").document(storeId)
            .updateData(["joinCode": newCode])
        return newCode
    }

    func getStoreJoinCode(storeId: String) async throws -> String {
        let doc = try await db.collection("stores").document(storeId).getDocument()
        guard let code = doc.data()?["joinCode"] as? String else {
            throw StoreRepoError.missingJoinCode
        }
        return code
    }

    // MARK: - Helpers

    private static func generateJoinCode() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }

    private func logFirestoreCreateError(_ error: Error, path: String) {
        let nsError = error as NSError
        print("[Stores] Create error path=\(path)")
        print("[Stores] NSError domain=\(nsError.domain) code=\(nsError.code)")
        print("[Stores] NSError userInfo=\(nsError.userInfo)")

        // ✅ Correct Firestore error decode
        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            let firestoreCode = FirestoreErrorCode(code)
            print("[Stores] FirestoreErrorCode=\(firestoreCode) (code=\(code))")
        }
    }

    private func wrapCreateError(_ error: Error, path: String) -> Error {
        let nsError = error as NSError
        var userInfo = nsError.userInfo
        userInfo["path"] = path

        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            let firestoreCode = FirestoreErrorCode(code)
            userInfo["firestoreCode"] = String(describing: firestoreCode)
            userInfo["firestoreCodeRaw"] = code.rawValue
        }

        return NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
    }

    private enum StoreRepoError: LocalizedError {
        case notAuthenticated
        case invalidName
        case missingJoinCode

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "You must be logged in."
            case .invalidName:
                return "Store name cannot be empty."
            case .missingJoinCode:
                return "Join code not found."
            }
        }
    }
}
