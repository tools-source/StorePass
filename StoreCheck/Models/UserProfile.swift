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

struct EmployeeSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let email: String?
    let storeIds: [String]
    let storeNames: [String]
    let userIsActive: Bool
    let hasInactiveMembership: Bool
}

typealias AppUser = UserProfile
