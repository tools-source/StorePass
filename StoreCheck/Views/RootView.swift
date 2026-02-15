import SwiftUI

struct RootView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        AuthGateView(authService: container.authService as! AuthService)
    }
}

private struct AuthGateView: View {
    @ObservedObject var authService: AuthService
    @State private var isBooting = true

    var body: some View {
        Group {
            if isBooting {
                ProgressView("Loading...")
            } else if let user = authService.currentUser {
                if user.role == .manager {
                    ManagerTabView()
                } else {
                    EmployeeTabView()
                }
            } else {
                LoginView()
            }
        }
        .task {
            guard isBooting else { return }
            await authService.restoreSession()
            isBooting = false
        }
    }
}
