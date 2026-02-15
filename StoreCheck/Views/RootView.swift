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
                if let role = authViewModel.currentUser?.role ?? authViewModel.resolvedRole {
                    switch role {
                    case .manager:
                        ManagerTabView()
                    case .employee:
                        EmployeeTabView()
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
