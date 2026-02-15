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
    var createdByManagerId: String?
}

struct EmployeeLink: Codable, Identifiable, Hashable {
    let id: String
    var employeeUserId: String
    var stores: [String]
    var isActive: Bool
    var createdAt: Date
}

struct EmployeeSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let email: String?
    let assignedStoreIds: [String]
    let linkedStoreIds: [String]
    let isActive: Bool
    let createdAt: Date
    let employeeUserId: String
}

typealias AppUser = UserProfile
