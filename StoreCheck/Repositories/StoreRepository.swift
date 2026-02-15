import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

struct StoreCreationResult {
    let store: Store
    let joinCode: String
}

struct JoinStoreResult {
    let storeId: String
    let storeName: String
    let alreadyJoined: Bool
}

protocol StoreRepositoryProtocol {
    func fetchStores(ids: [String]?) async throws -> [Store]
    func fetchManagerStores(managerId: String) async throws -> [Store]
    func upsertStore(_ store: Store) async throws
    func deleteStore(id: String) async throws
    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async throws -> StoreCreationResult
    func rotateStoreCode(storeId: String) async throws -> String
    func getStoreJoinCode(storeId: String) async throws -> String
    func joinStoreByCode(code: String) async throws -> JoinStoreResult
}

final class FirestoreStoreRepository: StoreRepositoryProtocol {
    private let db = Firestore.firestore()

    func fetchStores(ids: [String]? = nil) async throws -> [Store] {
        let snapshot: QuerySnapshot
        if let ids {
            if ids.isEmpty { return [] }
            snapshot = try await db.collection("stores").whereField(FieldPath.documentID(), in: ids).getDocuments()
        } else {
            snapshot = try await db.collection("stores").order(by: "name").getDocuments()
        }
        return snapshot.documents.map(decodeStore)
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        let snapshot = try await db.collection("stores")
            .whereField("managerId", isEqualTo: managerId)
            .order(by: "name")
            .getDocuments()
        return snapshot.documents.map(decodeStore)
    }

    func upsertStore(_ store: Store) async throws {
        try await db.collection("stores").document(store.id).setData([
            "name": store.name,
            "address": store.address,
            "latitude": store.latitude,
            "longitude": store.longitude,
            "radiusMeters": store.radiusMeters,
            "isActive": store.isActive,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func deleteStore(id: String) async throws {
        try await db.collection("stores").document(id).delete()
    }

    func createStore(name: String, address: String, latitude: Double, longitude: Double, radiusMeters: Int) async throws -> StoreCreationResult {
        let response = try await callable(name: "createStore", payload: [
            "name": name,
            "address": address,
            "latitude": latitude,
            "longitude": longitude,
            "radiusMeters": radiusMeters
        ])

        guard let storeId = response["storeId"] as? String,
              let joinCode = response["joinCode"] as? String else {
            throw NSError(domain: "StorePass", code: 5001, userInfo: [NSLocalizedDescriptionKey: "Unable to create store."])
        }

        let store = Store(
            id: storeId,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            isActive: true,
            managerId: Auth.auth().currentUser?.uid,
            createdAt: Date(),
            updatedAt: Date(),
            joinCodeLast4: String(joinCode.suffix(4))
        )
        return StoreCreationResult(store: store, joinCode: joinCode)
    }

    func rotateStoreCode(storeId: String) async throws -> String {
        let response = try await callable(name: "rotateStoreCode", payload: ["storeId": storeId])
        guard let joinCode = response["joinCode"] as? String else {
            throw NSError(domain: "StorePass", code: 5002, userInfo: [NSLocalizedDescriptionKey: "Unable to rotate code."])
        }
        return joinCode
    }

    func getStoreJoinCode(storeId: String) async throws -> String {
        let response = try await callable(name: "getStoreJoinCode", payload: ["storeId": storeId])
        guard let joinCode = response["joinCode"] as? String else {
            throw NSError(domain: "StorePass", code: 5003, userInfo: [NSLocalizedDescriptionKey: "Unable to reveal code."])
        }
        return joinCode
    }

    func joinStoreByCode(code: String) async throws -> JoinStoreResult {
        let response = try await callable(name: "joinStoreByCode", payload: ["code": code])
        guard let storeId = response["storeId"] as? String,
              let storeName = response["storeName"] as? String else {
            throw NSError(domain: "StorePass", code: 5004, userInfo: [NSLocalizedDescriptionKey: "Unexpected response while joining store."])
        }

        return JoinStoreResult(
            storeId: storeId,
            storeName: storeName,
            alreadyJoined: response["alreadyJoined"] as? Bool ?? false
        )
    }

    private func decodeStore(_ document: QueryDocumentSnapshot) -> Store {
        let data = document.data()
        return Store(
            id: document.documentID,
            name: data["name"] as? String ?? "Unnamed Store",
            address: data["address"] as? String ?? "",
            latitude: data["latitude"] as? Double ?? data["lat"] as? Double ?? 0,
            longitude: data["longitude"] as? Double ?? data["lng"] as? Double ?? 0,
            radiusMeters: data["radiusMeters"] as? Int ?? 150,
            isActive: data["isActive"] as? Bool ?? true,
            managerId: data["managerId"] as? String,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue(),
            joinCodeLast4: data["joinCodeLast4"] as? String
        )
    }

    private func callable(name: String, payload: [String: Any]) async throws -> [String: Any] {
        guard let user = Auth.auth().currentUser else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
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
