import AuthenticationServices
import XCTest
@testable import StoreCheck

@MainActor
final class AuthViewModelTests: XCTestCase {
    func testManagerRequestDeniedForNonManagerProfile() async {
        let authService = MockAuthService()
        authService.nextAppleResult = AppleSignInResult(
            identity: AuthIdentity(userId: "user-1", fullName: "Taylor", email: "taylor@storepass.app", provider: "apple")
        )

        let roleRepository = MockRoleProfileRepository()
        roleRepository.ensureHandler = { uid, name, email, provider, requestedRole in
            _ = uid
            _ = name
            _ = email
            _ = provider
            XCTAssertEqual(requestedRole, .manager)
            return .resolved(
                UserAccessProfile(
                    id: "user-1",
                    name: "Taylor",
                    email: "taylor@storepass.app",
                    role: .employee,
                    isActive: true,
                    provider: "apple",
                    createdAt: Date(),
                    lastLoginAt: Date(),
                    assignedStoreIds: []
                )
            )
        }

        let viewModel = AuthViewModel(authService: authService, roleProfileRepository: roleRepository)
        await viewModel.signInWithApple(requestedRole: .manager)

        XCTAssertTrue(viewModel.showManagerAccessRequired)
        XCTAssertEqual(viewModel.managerAccessMessage, "This account is not configured as a manager.")
        XCTAssertEqual(authService.signOutCallCount, 1)

        if case .signedOut = viewModel.authState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected signedOut state")
        }
    }

    func testDeleteCurrentAccountClearsStateAndCallsDependencies() async throws {
        let authService = MockAuthService()
        authService.nextManualResult = ManualEmployeeSignInResult(
            identity: AuthIdentity(userId: "employee-1", fullName: "Avery", email: "avery@storepass.app", provider: "manual.employee")
        )

        let roleRepository = MockRoleProfileRepository()
        roleRepository.ensureHandler = { uid, name, email, provider, requestedRole in
            _ = requestedRole
            return .resolved(
                UserAccessProfile(
                    id: uid,
                    name: name ?? "Avery",
                    email: email,
                    role: .employee,
                    isActive: true,
                    provider: provider,
                    createdAt: Date(),
                    lastLoginAt: Date(),
                    assignedStoreIds: []
                )
            )
        }

        let viewModel = AuthViewModel(authService: authService, roleProfileRepository: roleRepository)
        await viewModel.signInManuallyAsEmployee(name: "Avery", email: "avery@storepass.app")

        try await viewModel.deleteCurrentAccount()

        XCTAssertEqual(roleRepository.softDeleteCalls.count, 1)
        XCTAssertEqual(roleRepository.softDeleteCalls.first?.uid, "employee-1")
        XCTAssertEqual(roleRepository.softDeleteCalls.first?.role, .employee)
        XCTAssertEqual(authService.deleteAuthAccountCallCount, 1)
        XCTAssertNil(viewModel.currentUser)

        if case .signedOut = viewModel.authState {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected signedOut state")
        }
    }
}

@MainActor
private final class MockAuthService: AuthServiceProtocol {
    var currentUser: AppUser?
    var currentIdentity: AuthIdentity?

    var nextAppleResult = AppleSignInResult(identity: AuthIdentity(userId: "", fullName: nil, email: nil, provider: "apple"))
    var nextManualResult = ManualEmployeeSignInResult(identity: AuthIdentity(userId: "", fullName: nil, email: nil, provider: "manual.employee"))
    var nextEmailResult = EmployeeEmailSignInResult(identity: AuthIdentity(userId: "", fullName: nil, email: nil, provider: "employee.email"))

    var signOutCallCount = 0
    var deleteAuthAccountCallCount = 0

    func setCurrentUser(_ user: AppUser?) {
        currentUser = user
    }

    func restoreSession(forceSignOutOnLaunch: Bool) async {
        if forceSignOutOnLaunch {
            currentIdentity = nil
            currentUser = nil
        }
    }

    func signInWithApple() async throws -> AppleSignInResult {
        currentIdentity = nextAppleResult.identity
        return nextAppleResult
    }

    func signInWithApple(authorizationResult: Result<ASAuthorization, Error>) throws -> AppleSignInResult {
        _ = authorizationResult
        currentIdentity = nextAppleResult.identity
        return nextAppleResult
    }

    func signInManuallyAsEmployee(name: String, email: String) async throws -> ManualEmployeeSignInResult {
        _ = name
        _ = email
        currentIdentity = nextManualResult.identity
        return nextManualResult
    }

    func signUpEmployee(name: String, email: String, password: String) async throws -> EmployeeEmailSignInResult {
        _ = name
        _ = email
        _ = password
        currentIdentity = nextEmailResult.identity
        return nextEmailResult
    }

    func signInEmployee(email: String, password: String) async throws -> EmployeeEmailSignInResult {
        _ = email
        _ = password
        currentIdentity = nextEmailResult.identity
        return nextEmailResult
    }

    func authUser() -> AuthIdentity? {
        currentIdentity
    }

    func signOut() async throws {
        signOutCallCount += 1
        currentIdentity = nil
        currentUser = nil
    }

    func deleteAuthAccount() async throws {
        deleteAuthAccountCallCount += 1
        currentIdentity = nil
        currentUser = nil
    }
}

@MainActor
private final class MockRoleProfileRepository: RoleProfileRepositoryProtocol {
    var ensureHandler: ((String, String?, String?, String, UserRole?) async throws -> RoleBootstrapStatus)?
    var softDeleteCalls: [(uid: String, role: UserRole)] = []

    func ensureUserProfile(
        uid: String,
        name: String?,
        email: String?,
        provider: String,
        requestedRole: UserRole?
    ) async throws -> RoleBootstrapStatus {
        if let ensureHandler {
            return try await ensureHandler(uid, name, email, provider, requestedRole)
        }
        return .setupRequired
    }

    func fetchUserProfile(uid: String) async throws -> UserAccessProfile? {
        _ = uid
        return nil
    }

    func updateDisplayName(uid: String, name: String) async throws -> UserAccessProfile {
        _ = uid
        return UserAccessProfile(
            id: uid,
            name: name,
            email: nil,
            role: .employee,
            isActive: true,
            provider: "mock",
            createdAt: Date(),
            lastLoginAt: Date(),
            assignedStoreIds: []
        )
    }

    func softDeleteAccount(uid: String, role: UserRole) async throws {
        softDeleteCalls.append((uid, role))
    }
}
