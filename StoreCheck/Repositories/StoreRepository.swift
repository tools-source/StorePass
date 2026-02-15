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
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreStoreRepository.db")
        return Firestore.firestore()
    }

    func fetchStores(ids: [String]? = nil) async throws -> [Store] {
        let snapshot: QuerySnapshot
        if let ids {
            if ids.isEmpty { return [] }
            snapshot = try await db.collection("stores")
                .whereField(FieldPath.documentID(), in: ids)
                .getDocuments()
        } else {
            snapshot = try await db.collection("stores")
                .order(by: "name")
                .getDocuments()
        }
        return snapshot.documents.map(decodeStore)
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        let snapshot = try await db.collection("stores")
            .whereField("managerId", isEqualTo: managerId)
            .getDocuments()

        let stores = snapshot.documents.map(decodeStore)
        return stores.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

        guard let storeId = stringValue(from: response, keys: ["storeId", "storeID", "store_id"]),
              let joinCode = stringValue(from: response, keys: ["joinCode", "join_code", "joincode"]) else {
            #if DEBUG
            print("[Stores] createStore unexpected payload: \(debugJSONString(from: response))")
            #endif
            throw NSError(domain: "StorePass", code: 5001, userInfo: [NSLocalizedDescriptionKey: "Unable to create store. Unexpected backend response."])
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
            name: stringValue(from: data, keys: ["name"]) ?? "Unnamed Store",
            address: stringValue(from: data, keys: ["address"]) ?? "",
            latitude: doubleValue(from: data, keys: ["latitude", "lat"]) ?? 0,
            longitude: doubleValue(from: data, keys: ["longitude", "lng", "lon"]) ?? 0,
            radiusMeters: intValue(from: data, keys: ["radiusMeters", "radius"]) ?? 150,
            isActive: boolValue(from: data, keys: ["isActive"]) ?? true,
            managerId: stringValue(from: data, keys: ["managerId"]),
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
            updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue(),
            joinCodeLast4: stringValue(from: data, keys: ["joinCodeLast4"])
        )
    }

    private func callable(name: String, payload: [String: Any]) async throws -> [String: Any] {
        FirebaseBootstrap.assertConfigured(context: "FirestoreStoreRepository.callable")

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

        let rawResponse = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        let object: [String: Any]

        do {
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            #if DEBUG
            print("[StoreCallable] \(name) non-JSON response (status=\(httpResponse.statusCode)): \(rawResponse)")
            #endif
            let message: String
            #if DEBUG
            message = "Backend returned invalid JSON: \(rawResponse)"
            #else
            message = "Backend returned invalid JSON."
            #endif
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        if let errorObj = object["error"] as? [String: Any] {
            #if DEBUG
            print("[StoreCallable] \(name) error payload: \(debugJSONString(from: object))")
            #endif
            let message = stringValue(from: errorObj, keys: ["message"]) ?? "Backend error"
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            #if DEBUG
            print("[StoreCallable] \(name) status=\(httpResponse.statusCode), response=\(debugJSONString(from: object))")
            #endif
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Backend request failed."])
        }

        if let result = object["result"] as? [String: Any] {
            return result
        }

        if let nestedData = object["data"] as? [String: Any] {
            return nestedData
        }

        if object["storeId"] != nil || object["storeID"] != nil || object["joinCode"] != nil {
            return object
        }

        #if DEBUG
        print("[StoreCallable] \(name) missing expected keys in payload: \(debugJSONString(from: object))")
        #endif
        return object
    }

    private func stringValue(from data: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let string = data[key] as? String, !string.isEmpty { return string }
            if let number = data[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }

    private func doubleValue(from data: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = data[key] as? Double { return value }
            if let value = data[key] as? Int { return Double(value) }
            if let value = data[key] as? NSNumber { return value.doubleValue }
            if let value = data[key] as? String, let double = Double(value) { return double }
        }
        return nil
    }

    private func intValue(from data: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = data[key] as? Int { return value }
            if let value = data[key] as? Double { return Int(value) }
            if let value = data[key] as? NSNumber { return value.intValue }
            if let value = data[key] as? String, let int = Int(value) { return int }
        }
        return nil
    }

    private func boolValue(from data: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = data[key] as? Bool { return value }
            if let value = data[key] as? NSNumber { return value.boolValue }
            if let value = data[key] as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
        }
        return nil
    }

    private func debugJSONString(from dictionary: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "\(dictionary)"
        }

        return string
    }
}
