import Foundation
import CryptoKit
import Security

enum KeychainStore {
    private static let service = "com.one-place.storecheck.applock"
    private static let account = "biometricsEnabled"

    static func setBiometricsEnabled(_ enabled: Bool) {
        let value = Data([enabled ? 1 : 0])

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func getBiometricsEnabled() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = data.first else {
            return false
        }

        return value == 1
    }
}

enum EmployeeCredentialStore {
    private static let service = "com.one-place.storecheck.employeeauth"

    private struct StoredCredential: Codable {
        let email: String
        let saltHex: String
        let passwordHashHex: String
        let createdAt: Date
    }

    static func register(email: String, password: String) throws {
        let normalizedEmail = try normalizeEmail(email)
        let normalizedPassword = try normalizePassword(password)

        guard !credentialExists(email: normalizedEmail) else {
            throw CloudKitClientError.invalidData("An account with this email already exists on this device.")
        }

        let salt = randomBytes(count: 16)
        let passwordHash = hash(password: normalizedPassword, salt: salt)
        let payload = StoredCredential(
            email: normalizedEmail,
            saltHex: salt.map { String(format: "%02x", $0) }.joined(),
            passwordHashHex: passwordHash,
            createdAt: Date()
        )

        let encoded = try JSONEncoder().encode(payload)
        let status = SecItemAdd(baseQuery(email: normalizedEmail).merging([
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new } as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw CloudKitClientError.invalidData("Unable to save employee credentials.")
        }
    }

    static func authenticate(email: String, password: String) throws {
        let normalizedEmail = try normalizeEmail(email)
        let normalizedPassword = try normalizePassword(password)

        guard let stored = try fetchCredential(email: normalizedEmail) else {
            throw CloudKitClientError.invalidData("No employee account found for this email on this device.")
        }

        guard let salt = dataFromHex(stored.saltHex) else {
            throw CloudKitClientError.invalidData("Stored credentials are corrupted.")
        }

        let computedHash = hash(password: normalizedPassword, salt: salt)
        guard computedHash == stored.passwordHashHex else {
            throw CloudKitClientError.invalidData("Incorrect email or password.")
        }
    }

    static func deleteCredential(email: String?) {
        guard let email,
              let normalized = try? normalizeEmail(email) else {
            return
        }
        SecItemDelete(baseQuery(email: normalized) as CFDictionary)
    }

    private static func credentialExists(email: String) -> Bool {
        (try? fetchCredential(email: email)) != nil
    }

    private static func fetchCredential(email: String) throws -> StoredCredential? {
        var query = baseQuery(email: email)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw CloudKitClientError.invalidData("Unable to load employee credentials.")
        }

        return try JSONDecoder().decode(StoredCredential.self, from: data)
    }

    private static func baseQuery(email: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email
        ]
    }

    private static func normalizeEmail(_ email: String) throws -> String {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = normalized.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else {
            throw CloudKitClientError.invalidData("Enter a valid employee email address.")
        }
        return normalized
    }

    private static func normalizePassword(_ password: String) throws -> String {
        let normalized = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 8 else {
            throw CloudKitClientError.invalidData("Password must be at least 8 characters.")
        }
        return normalized
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func hash(password: String, salt: Data) -> String {
        let payload = salt + Data(password.utf8)
        let digest = SHA256.hash(data: payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func dataFromHex(_ value: String) -> Data? {
        let chars = Array(value)
        guard chars.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)

        var index = 0
        while index < chars.count {
            let next = index + 2
            guard let byte = UInt8(String(chars[index..<next]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }

        return Data(bytes)
    }
}
