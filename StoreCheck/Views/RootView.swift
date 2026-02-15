import SwiftUI

struct RootView: View {
    @StateObject private var authViewModel = AuthViewModel(authService: AppContainer.shared.authService)

    var body: some View {
        SessionRouterView()
            .environmentObject(authViewModel)
    }
}

private struct SessionRouterView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel

    var body: some View {
        Group {
            switch authViewModel.authState {
            case .signedOut:
                LoginView()
            case .signedIn:
                if authViewModel.resolvedRole == nil {
                    ProgressView("Loading account")
                        .tint(.white)
                } else if authViewModel.resolvedRole == .manager {
                    ManagerTabView()
                } else {
                    EmployeeTabView()
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
