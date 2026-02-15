import Foundation

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let authService: AuthServiceProtocol
    let role: UserRole

    init(role: UserRole, authService: AuthServiceProtocol) {
        self.role = role
        self.authService = authService
    }

    func login() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await authService.login(email: email, password: password, expectedRole: role)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
