import Foundation

struct UserProfile: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var email: String?
    var role: UserRole
    var createdAt: Date
    var lastLoginAt: Date
    var provider: String
    var assignedStoreIds: [String]
    var isActive: Bool
}

typealias AppUser = UserProfile
