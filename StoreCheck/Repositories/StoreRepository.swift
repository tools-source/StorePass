import CryptoKit
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
    func upsertStore(_ store: Store) async throws
    func deleteStore(id: String) async throws
    func createStore(name: String, address: String, lat: Double, lng: Double, radiusMeters: Int) async throws -> StoreCreationResult
    func rotateJoinCode(storeId: String) async throws -> String
    func joinStoreByCode(code: String) async throws -> JoinStoreResult
}

final class FirestoreStoreRepository: StoreRepositoryProtocol {
    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreStoreRepository.db")
        return Firestore.firestore()
    }

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
        var data: [String: Any] = [
            "name": store.name,
            "address": store.address,
            "lat": store.lat,
            "lng": store.lng,
            "radiusMeters": store.radiusMeters,
            "isActive": store.isActive
        ]
        if let joinCodeLast4 = store.joinCodeLast4 {
            data["joinCodeLast4"] = joinCodeLast4
        }

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

    func createStore(name: String, address: String, lat: Double, lng: Double, radiusMeters: Int) async throws -> StoreCreationResult {
        guard let managerId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "StorePass", code: 5001, userInfo: [NSLocalizedDescriptionKey: "You must be signed in to create stores."])
        }

        let code = Self.generateJoinCode()
        let normalizedCode = Self.normalizeCode(code)
        let storeRef = db.collection("stores").document()

        do {
            try await storeRef.setData([
                "name": name,
                "address": address,
                "lat": lat,
                "lng": lng,
                "radiusMeters": radiusMeters,
                "managerId": managerId,
                "createdAt": FieldValue.serverTimestamp(),
                "joinCodeHash": Self.sha256(normalizedCode),
                "joinCodeLast4": String(code.suffix(4)),
                "isActive": true
            ], merge: false)

            let created = Store(
                id: storeRef.documentID,
                name: name,
                address: address,
                lat: lat,
                lng: lng,
                radiusMeters: radiusMeters,
                isActive: true,
                managerId: managerId,
                createdAt: Date(),
                joinCodeLast4: String(code.suffix(4))
            )
            return StoreCreationResult(store: created, joinCode: code)
        } catch {
            throw mapFirestoreError(error)
        }
    }

    func rotateJoinCode(storeId: String) async throws -> String {
        let response = try await callFirebaseFunction(name: "rotateJoinCode", payload: ["storeId": storeId])
        guard let joinCode = response["joinCode"] as? String else {
            throw NSError(domain: "StorePass", code: 5002, userInfo: [NSLocalizedDescriptionKey: "Unable to rotate join code. Try again."])
        }
        return joinCode
    }

    func joinStoreByCode(code: String) async throws -> JoinStoreResult {
        let normalizedCode = Self.normalizeCode(code)
        guard !normalizedCode.isEmpty else {
            throw NSError(domain: "StorePass", code: 5003, userInfo: [NSLocalizedDescriptionKey: "Please enter a join code."])
        }

        let response = try await callFirebaseFunction(name: "joinStoreByCode", payload: ["code": normalizedCode])

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

    private func decodeStore(document: QueryDocumentSnapshot) -> Store? {
        let data = document.data()
        return Store(
            id: document.documentID,
            name: data["name"] as? String ?? "Unnamed Store",
            address: data["address"] as? String ?? "",
            lat: data["lat"] as? Double ?? 0,
            lng: data["lng"] as? Double ?? 0,
            radiusMeters: data["radiusMeters"] as? Int ?? 150,
            isActive: data["isActive"] as? Bool ?? true,
            managerId: data["managerId"] as? String,
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue(),
            joinCodeLast4: data["joinCodeLast4"] as? String
        )
    }

    private func callFirebaseFunction(name: String, payload: [String: Any]) async throws -> [String: Any] {
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

    private static func normalizeCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func generateJoinCode(length: Int = 8) -> String {
        let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).compactMap { _ in charset.randomElement() })
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
