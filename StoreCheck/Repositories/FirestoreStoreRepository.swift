import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

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

        var stores: [Store] = []
        stores.reserveCapacity(snapshot.documents.count)

        for document in snapshot.documents {
            do {
                let store = try document.data(as: Store.self)
                stores.append(store)
            } catch {
                print("[Stores] Skipping invalid store document id=\(document.documentID). Error: \(error)")
            }
        }

        return stores
    }

    func fetchManagerStores(managerId: String) async throws -> [Store] {
        let primarySnapshot = try await db.collection("stores")
            .whereField("managerId", isEqualTo: managerId)
            .getDocuments()

        let fallbackSnapshot = try await db.collection("stores")
            .whereField("ownerId", isEqualTo: managerId)
            .getDocuments()

        var byId: [String: Store] = [:]
        for document in primarySnapshot.documents + fallbackSnapshot.documents {
            do {
                let store = try document.data(as: Store.self)
                byId[document.documentID] = store
            } catch {
                print("[Stores] Skipping invalid manager store document id=\(document.documentID). Error: \(error)")
            }
        }

        return byId.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsertStore(_ store: Store) async throws {
        try await db.collection("stores").document(store.id).setData([
            "id": store.id, // ✅ keep id in doc data for Codable Store decoding
            "name": store.name,
            "address": store.address,
            "latitude": store.latitude,
            "longitude": store.longitude,
            "radiusMeters": store.radiusMeters,
            "isActive": store.isActive,
            "managerId": store.managerId as Any,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func deleteStore(id: String) async throws {
        try await db.collection("stores").document(id).delete()
    }

    func createStore(
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Int
    ) async throws -> StoreCreationResult {
        guard let user = auth.currentUser else {
            throw StoreCreationError.notSignedIn
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw StoreCreationError.invalidName
        }

        let managerDoc = try await db.collection("managers").document(user.uid).getDocument()
        guard let managerData = managerDoc.data() else {
            throw StoreCreationError.missingManagerProfile
        }

        guard managerData.keys.contains("isActive") else {
            throw StoreCreationError.missingManagerActiveState
        }

        guard (managerData["isActive"] as? Bool) == true else {
            throw StoreCreationError.managerInactive
        }

        let userDoc = try await db.collection("users").document(user.uid).getDocument()
        if let userData = userDoc.data() {
            let role = (userData["role"] as? String)?.lowercased()
            if role != "manager" {
                throw StoreCreationError.notAManager
            }

            if (userData["isActive"] as? Bool) != true {
                throw StoreCreationError.userNotActive
            }
        }

        let joinCode = Self.generateJoinCode(length: 8)
        let storeRef = db.collection("stores").document()

        var payload: [String: Any] = [
            "id": storeRef.documentID, // ✅ FIX: required by Store decoding if Store has `id`
            "name": trimmedName,
            "managerId": user.uid,
            "ownerId": user.uid,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "joinCode": joinCode,
            "joinCodeLast4": String(joinCode.suffix(4)),
            "isActive": true
        ]

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAddress.isEmpty {
            payload["address"] = trimmedAddress
        }

        if Self.isValidCoordinate(latitude: latitude, longitude: longitude) {
            payload["location"] = GeoPoint(latitude: latitude, longitude: longitude)
            payload["latitude"] = latitude
            payload["longitude"] = longitude
            if radiusMeters > 0 {
                payload["radiusMeters"] = radiusMeters
            }
        }

        do {
            try await storeRef.setData(payload)
            let saved = try await storeRef.getDocument()
            let store = try saved.data(as: Store.self)
            return StoreCreationResult(store: store, joinCode: joinCode)
        } catch {
            logFirestoreCreateError(error, path: storeRef.path)
            throw wrapCreateError(error, path: storeRef.path)
        }
    }

    func rotateStoreCode(storeId: String) async throws -> String {
        let response = try await callable(
            name: "rotateStoreCode",
            payload: ["storeId": storeId],
            responseType: JoinCodePayload.self
        )
        return response.joinCode
    }

    func getStoreJoinCode(storeId: String) async throws -> String {
        let response = try await callable(
            name: "getStoreJoinCode",
            payload: ["storeId": storeId],
            responseType: JoinCodePayload.self
        )
        return response.joinCode
    }

    func joinStoreByCode(code: String) async throws -> JoinStoreResult {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedCode.count >= 6 else {
            throw NSError(
                domain: "StorePass",
                code: 4005,
                userInfo: [NSLocalizedDescriptionKey: "Enter a valid join code (at least 6 characters)."]
            )
        }

        do {
            let response = try await callable(name: "joinStoreByCode", payload: ["code": normalizedCode], responseType: JoinStorePayload.self)
            return JoinStoreResult(storeId: response.storeId, storeName: response.storeName, alreadyJoined: response.alreadyJoined ?? false)
        } catch {
            let nsError = error as NSError
            if nsError.code == 404 || nsError.code >= 500 {
                throw NSError(
                    domain: nsError.domain,
                    code: nsError.code,
                    userInfo: [NSLocalizedDescriptionKey: "Join service unavailable. Please try again."]
                )
            }
            throw error
        }
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
            let message = "Backend request failed (status=\(httpResponse.statusCode)). \(backendMessage). Raw: \(rawResponse)"
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = "Backend request failed (status=\(httpResponse.statusCode)). Raw: \(rawResponse)"
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

    private static func generateJoinCode(length: Int) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0 ..< max(6, min(10, length))).compactMap { _ in charset.randomElement() })
    }

    private static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
    }

    private func logFirestoreCreateError(_ error: Error, path: String) {
        let nsError = error as NSError
        print("[Stores] Create error path=\(path)")
        print("[Stores] NSError domain=\(nsError.domain) code=\(nsError.code)")
        print("[Stores] NSError userInfo=\(nsError.userInfo)")

        // ✅ FIX: correct Firestore error decode for your Firebase version
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

        // ✅ FIX: correct Firestore error decode for your Firebase version
        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            let firestoreCode = FirestoreErrorCode(code)
            userInfo["firestoreCode"] = String(describing: firestoreCode)
            userInfo["firestoreCodeRaw"] = code.rawValue
        }

        return NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
    }
}

private enum StoreCreationError: LocalizedError {
    case notSignedIn
    case invalidName
    case missingManagerProfile
    case missingManagerActiveState
    case managerInactive
    case notAManager
    case userNotActive

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "You must be signed in to create a store."
        case .invalidName:
            return "Store name is required."
        case .missingManagerProfile:
            return "Manager profile not found. Please contact support."
        case .missingManagerActiveState:
            return "Manager profile is missing activation status. Please contact support."
        case .managerInactive:
            return "Your manager account is inactive. Contact an administrator."
        case .notAManager:
            return "Only active managers can create stores."
        case .userNotActive:
            return "Your account is not active. Contact an administrator."
        }
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

        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected one of keys: \(keys)"
            )
        )
    }
}
