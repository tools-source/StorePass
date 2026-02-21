import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

// MARK: - Domain Models (single source of truth)


struct UserAccessProfile: Equatable {
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

// MARK: - Bootstrap Result

enum RoleBootstrapStatus: Equatable {
    case resolved(UserAccessProfile)
    case setupRequired

    static func == (lhs: RoleBootstrapStatus, rhs: RoleBootstrapStatus) -> Bool {
        switch (lhs, rhs) {
        case (.setupRequired, .setupRequired):
            return true
        case (.resolved(let a), .resolved(let b)):
            // Compare only routing-critical fields
            return a.id == b.id && a.role == b.role && a.isActive == b.isActive
        default:
            return false
        }
    }
}

// MARK: - Optional convenience profiles (keep only if used elsewhere)

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

// MARK: - Protocol

protocol RoleProfileRepositoryProtocol {
    func ensureUserProfile(
        uid: String,
        name: String,
        email: String?,
        provider: String,
        requestedRole: UserRole?
    ) async throws -> RoleBootstrapStatus

    func fetchUserProfile(uid: String) async throws -> UserAccessProfile?
}

// MARK: - Repository

final class FirestoreRoleProfileRepository: RoleProfileRepositoryProtocol {

    private var db: Firestore {
        FirebaseBootstrap.assertConfigured(context: "FirestoreRoleProfileRepository.db")
        return Firestore.firestore()
    }

    private var auth: Auth {
        FirebaseBootstrap.assertConfigured(context: "FirestoreRoleProfileRepository.auth")
        return Auth.auth()
    }

    private var firebaseApp: FirebaseApp {
        FirebaseBootstrap.assertConfigured(context: "FirestoreRoleProfileRepository.firebaseApp")
        guard let app = FirebaseApp.app() else {
            fatalError("Firebase app is unexpectedly unavailable.")
        }
        return app
    }

    func ensureUserProfile(
        uid: String,
        name: String,
        email: String?,
        provider: String,
        requestedRole: UserRole?
    ) async throws -> RoleBootstrapStatus {

        let userRef = db.collection("users").document(uid)
        let userDoc = try await userRef.getDocument()
        log(event: "ensure_start", uid: uid, requestedRole: requestedRole, fields: [
            "userDocExists": userDoc.exists
        ])

        if userDoc.exists {
            // Break into a typed dictionary to avoid compiler “unable to type-check” issues
            var update: [String: Any] = [
                "name": name,
                "provider": provider,
                "lastLoginAt": FieldValue.serverTimestamp()
            ]
            update["email"] = email as Any

            try await userRef.setData(update, merge: true)
        } else {
            // New user must pick role (or we go to setup screen)
            guard let requestedRole = requestedRole else {
                log(event: "ensure_missing_role_selection", uid: uid, requestedRole: nil)
                return .setupRequired
            }

            // Role must be set via trusted backend (Cloud Function), not client rules
            _ = try await setUserRole(requestedRole: requestedRole, name: name, email: email, provider: provider)
        }

        // Fetch and resolve
        guard let fetched = try await fetchUserProfileRaw(uid: uid) else {
            throw NSError(domain: "StorePass", code: 3001, userInfo: [
                NSLocalizedDescriptionKey: "Unable to load profile."
            ])
        }

        if let role = fetched.role {
            log(event: "ensure_resolved", uid: uid, requestedRole: requestedRole, fields: [
                "role": role.rawValue,
                "isActive": fetched.isActive
            ])
            return .resolved(fetched.toUserAccessProfile(role: role))
        }

        // Role still missing → setup required unless we have requestedRole
        guard let requestedRole = requestedRole else {
            log(event: "ensure_role_missing", uid: uid, requestedRole: nil)
            return .setupRequired
        }

        _ = try await setUserRole(requestedRole: requestedRole, name: name, email: email, provider: provider)

        guard let postRole = try await fetchUserProfile(uid: uid) else {
            throw NSError(domain: "StorePass", code: 3002, userInfo: [
                NSLocalizedDescriptionKey: "Unable to load profile after role bootstrap."
            ])
        }

        log(event: "ensure_bootstrapped_role", uid: uid, requestedRole: requestedRole, fields: [
            "role": postRole.role.rawValue,
            "isActive": postRole.isActive
        ])

        return .resolved(postRole)
    }

    func fetchUserProfile(uid: String) async throws -> UserAccessProfile? {
        guard let raw = try await fetchUserProfileRaw(uid: uid),
              let role = raw.role else {
            return nil
        }
        return raw.toUserAccessProfile(role: role)
    }

    // MARK: - Raw fetch

    private func fetchUserProfileRaw(uid: String) async throws -> PartialUserAccessProfile? {
        let doc = try await db.collection("users").document(uid).getDocument()
        guard let data = doc.data() else { return nil }

        let roleString = (data["role"] as? String)?.lowercased() ?? ""
        let parsedRole: UserRole? = UserRole(rawValue: roleString)

        return PartialUserAccessProfile(
            id: uid,
            name: data["name"] as? String ?? "StorePass User",
            email: data["email"] as? String,
            role: parsedRole,
            isActive: data["isActive"] as? Bool ?? true,
            provider: data["provider"] as? String ?? "unknown",
            createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
            lastLoginAt: (data["lastLoginAt"] as? Timestamp)?.dateValue() ?? Date(),
            assignedStoreIds: data["assignedStoreIds"] as? [String] ?? []
        )
    }

    // MARK: - Backend role set

    private func setUserRole(
        requestedRole: UserRole,
        name: String,
        email: String?,
        provider: String
    ) async throws -> [String: Any] {

        guard let user = auth.currentUser else {
            throw NSError(domain: "StorePass", code: 4001, userInfo: [
                NSLocalizedDescriptionKey: "You must be signed in."
            ])
        }

        let projectID = firebaseApp.options.projectID ?? ""
        guard !projectID.isEmpty else {
            throw NSError(domain: "StorePass", code: 4002, userInfo: [
                NSLocalizedDescriptionKey: "Firebase project is not configured correctly."
            ])
        }

        let token = try await user.getIDToken()
        guard let url = URL(string: "https://us-central1-\(projectID).cloudfunctions.net/setUserRole") else {
            throw NSError(domain: "StorePass", code: 4003, userInfo: [
                NSLocalizedDescriptionKey: "Unable to build backend URL."
            ])
        }

        let payload: [String: Any] = [
            "requestedRole": requestedRole.rawValue,
            "name": name,
            "email": email as Any,
            "provider": provider
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": payload])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "StorePass", code: 4004, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected backend response."
            ])
        }

        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if let errorObj = object["error"] as? [String: Any] {
            let message = errorObj["message"] as? String ?? "Backend error"
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "StorePass", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Backend request failed."
            ])
        }

        log(event: "set_user_role_success", uid: user.uid, requestedRole: requestedRole)
        return object["result"] as? [String: Any] ?? object
    }

    // MARK: - Logging

    private func log(event: String, uid: String, requestedRole: UserRole?, fields: [String: Any] = [:]) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let role = requestedRole?.rawValue ?? "nil"
        let thread = Thread.isMainThread ? "main" : "background"
        print("[RoleRepo] ts=\(timestamp) event=\(event) uid=\(uid) requestedRole=\(role) thread=\(thread) fields=\(fields)")
    }
}

// MARK: - Partial profile (internal)

private struct PartialUserAccessProfile {
    let id: String
    let name: String
    let email: String?
    let role: UserRole?
    let isActive: Bool
    let provider: String
    let createdAt: Date
    let lastLoginAt: Date
    let assignedStoreIds: [String]

    func toUserAccessProfile(role: UserRole) -> UserAccessProfile {
        UserAccessProfile(
            id: id,
            name: name,
            email: email,
            role: role,
            isActive: isActive,
            provider: provider,
            createdAt: createdAt,
            lastLoginAt: lastLoginAt,
            assignedStoreIds: assignedStoreIds
        )
    }
}
