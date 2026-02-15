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

    private var auth: Auth {
        FirebaseBootstrap.assertConfigured(context: "FirestoreStoreRepository.auth")
        return Auth.auth()
    }

    private var firebaseApp: FirebaseApp {
        FirebaseBootstrap.assertConfigured(context: "FirestoreStoreRepository.firebaseApp")
        guard let app = FirebaseApp.app() else {
            fatalError("Firebase app is unexpectedly unavailable.")
        }
        return app
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
        let payload = try await callable(
            name: "createStore",
            payload: [
                "name": name,
                "address": address,
                "latitude": latitude,
                "longitude": longitude,
                "radiusMeters": radiusMeters
            ],
            responseType: CreateStorePayload.self
        )

        let store = Store(
            id: payload.storeId,
            name: name,
            address: address,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            isActive: true,
            managerId: auth.currentUser?.uid,
            createdAt: Date(),
            updatedAt: Date(),
            joinCodeLast4: String(payload.joinCode.suffix(4))
        )

        return StoreCreationResult(store: store, joinCode: payload.joinCode)
    }

    func rotateStoreCode(storeId: String) async throws -> String {
        let response = try await callable(name: "rotateStoreCode", payload: ["storeId": storeId], responseType: JoinCodePayload.self)
        return response.joinCode
    }

    func getStoreJoinCode(storeId: String) async throws -> String {
        let response = try await callable(name: "getStoreJoinCode", payload: ["storeId": storeId], responseType: JoinCodePayload.self)
        return response.joinCode
    }

    func joinStoreByCode(code: String) async throws -> JoinStoreResult {
        let response = try await callable(name: "joinStoreByCode", payload: ["code": code], responseType: JoinStorePayload.self)
        return JoinStoreResult(storeId: response.storeId, storeName: response.storeName, alreadyJoined: response.alreadyJoined ?? false)
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

    private func callable<T: Decodable>(name: String, payload: [String: Any], responseType: T.Type) async throws -> T {
        FirebaseBootstrap.assertConfigured(context: "FirestoreStoreRepository.callable")

        guard let user = auth.currentUser else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
        }

        let projectID = firebaseApp.options.projectID ?? ""
        guard !projectID.isEmpty else {
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
        let decoder = JSONDecoder()

        let wrapped = try? decoder.decode(BackendEnvelope<T>.self, from: data)
        if let backendMessage = wrapped?.error?.message {
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: backendMessage])
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            #if DEBUG
            let message = "Backend request failed (status=\(httpResponse.statusCode)). Raw: \(rawResponse)"
            #else
            let message = "Backend request failed."
            #endif
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        if let payload = wrapped?.result ?? wrapped?.data {
            return payload
        }

        if let directPayload = try? decoder.decode(T.self, from: data) {
            return directPayload
        }

        #if DEBUG
        let message = "Backend returned invalid JSON shape for \(name). Raw: \(rawResponse)"
        #else
        let message = "Backend returned invalid JSON."
        #endif
        throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
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
}

private struct BackendEnvelope<T: Decodable>: Decodable {
    let result: T?
    let data: T?
    let error: BackendErrorPayload?
}

private struct BackendErrorPayload: Decodable {
    let message: String?
}

private struct JoinCodePayload: Decodable {
    let joinCode: String

    enum CodingKeys: String, CodingKey {
        case joinCode
        case join_code
        case joincode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        joinCode = try container.decodeFirstString(forKeys: [.joinCode, .join_code, .joincode])
    }
}

private struct CreateStorePayload: Decodable {
    let storeId: String
    let joinCode: String

    enum CodingKeys: String, CodingKey {
        case storeId
        case storeID
        case store_id
        case joinCode
        case join_code
        case joincode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeId = try container.decodeFirstString(forKeys: [.storeId, .storeID, .store_id])
        joinCode = try container.decodeFirstString(forKeys: [.joinCode, .join_code, .joincode])
    }
}

private struct JoinStorePayload: Decodable {
    let storeId: String
    let storeName: String
    let alreadyJoined: Bool?

    enum CodingKeys: String, CodingKey {
        case storeId
        case storeID
        case store_id
        case storeName
        case alreadyJoined
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeId = try container.decodeFirstString(forKeys: [.storeId, .storeID, .store_id])
        storeName = try container.decode(String.self, forKey: .storeName)
        alreadyJoined = try container.decodeIfPresent(Bool.self, forKey: .alreadyJoined)
    }
}

private extension KeyedDecodingContainer {
    func decodeFirstString(forKeys keys: [K]) throws -> String {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key), !value.isEmpty {
                return value
            }

            if let number = try decodeIfPresent(Int.self, forKey: key) {
                return String(number)
            }
        }

        throw DecodingError.keyNotFound(keys[0], DecodingError.Context(codingPath: codingPath, debugDescription: "Expected one of keys: \(keys)"))
    }
}
