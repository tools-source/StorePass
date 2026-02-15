import Foundation

enum UserRole: String, Codable, CaseIterable {
    case employee
    case manager
}

struct UserProfile: Codable, Identifiable {
    let id: String
    var name: String
    var email: String
    var role: UserRole
    var assignedStoreIds: [String]
    var isActive: Bool
    var createdAt: Date
}
