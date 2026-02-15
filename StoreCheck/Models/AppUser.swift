import Foundation

struct AppUser: Codable, Identifiable {
    let id: String
    var name: String
    var email: String
    var role: UserRole
    var createdAt: Date
    var lastLoginAt: Date
    var provider: String
    var assignedStoreIds: [String]
    var isActive: Bool

    init(
        id: String,
        name: String,
        email: String,
        role: UserRole = .employee,
        createdAt: Date = Date(),
        lastLoginAt: Date = Date(),
        provider: String,
        assignedStoreIds: [String] = [],
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
        self.provider = provider
        self.assignedStoreIds = assignedStoreIds
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case email
        case role
        case createdAt
        case lastLoginAt
        case provider
        case assignedStoreIds
        case isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "StoreCheck User"
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? "unknown@privaterelay.appleid.com"
        role = try container.decodeIfPresent(UserRole.self, forKey: .role) ?? .employee
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastLoginAt = try container.decodeIfPresent(Date.self, forKey: .lastLoginAt) ?? Date()
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "unknown"
        assignedStoreIds = try container.decodeIfPresent([String].self, forKey: .assignedStoreIds) ?? []
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
    }
}

typealias UserProfile = AppUser
