import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appContainer: AppContainer

    var body: some View {
        RootContentView(authService: appContainer.authService)
    }
}

private struct RootContentView: View {
    @StateObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var appContainer: AppContainer

    init(authService: AuthService) {
        _authViewModel = StateObject(wrappedValue: AuthViewModel(authService: authService))
    }

    var body: some View {
        SessionRouterView()
            .environmentObject(authViewModel)
    }
}

private struct SessionRouterView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var appContainer: AppContainer

    var body: some View {
        Group {
            switch authViewModel.authState {
            case .signedOut:
                LoginView()
            case .signedIn:
                if let role = authViewModel.currentUser?.role ?? authViewModel.resolvedRole {
                    switch role {
                    case .manager:
                        ManagerTabView(container: appContainer)
                    case .employee:
                        EmployeeTabView(container: appContainer)
                    }
                } else {
                    ProgressView("Loading account")
                        .tint(.white)
                }
            }
        }
        .background(DS.Colors.background.ignoresSafeArea())
        .task {
            guard authViewModel.authState == .signedOut else { return }
            await authViewModel.restoreSession()
        }
    }
}
