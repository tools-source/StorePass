import Foundation

@MainActor
final class RootViewModel: ObservableObject {
    @Published var isLoading = true

    private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
    }

    func boot() async {
        await authService.restoreSession()
        isLoading = false
    }
}
