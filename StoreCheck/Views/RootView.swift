import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appContainer: AppContainer

    var body: some View {
        RootContentView(authService: appContainer.authService)
    }
}

private struct RootContentView: View {
    enum BootState {
        case launching
        case needsLogin
        case resolvingRole
        case authenticated(user: AppUser)
    }

    @StateObject private var authViewModel: AuthViewModel
    @State private var bootState: BootState = .launching
    @EnvironmentObject private var appContainer: AppContainer

    init(authService: AuthService) {
        _authViewModel = StateObject(wrappedValue: AuthViewModel(authService: authService))
    }

    var body: some View {
        Group {
            switch bootState {
            case .launching, .resolvingRole:
                ProgressView("Loading account")
                    .tint(.white)
            case .needsLogin:
                LoginView()
            case .authenticated(let user):
                if authViewModel.resolvedRole == nil {
                    ProgressView("Resolving role")
                        .tint(.white)
                } else {
                    switch user.role {
                    case .manager:
                        ManagerHomeView(container: appContainer)
                    case .employee:
                        EmployeeTabView(container: appContainer)
                    }
                }
            }
        }
        .background(DS.Colors.background.ignoresSafeArea())
        .environmentObject(authViewModel)
        .task { await boot() }
        .onChange(of: authViewModel.authState) { _, newState in
            if case .signedOut = newState {
                bootState = .needsLogin
            }
        }
        .onChange(of: authViewModel.currentUser) { _, newUser in
            guard let newUser else {
                bootState = .needsLogin
                return
            }

            if authViewModel.resolvedRole == nil {
                bootState = .resolvingRole
            } else {
                bootState = .authenticated(user: newUser)
            }
        }
        .onChange(of: authViewModel.resolvedRole) { _, role in
            if role != nil, let user = authViewModel.currentUser {
                bootState = .authenticated(user: user)
            }
        }
    }

    private func boot() async {
        guard case .launching = bootState else { return }

        await authViewModel.restoreSession(forceSignOutOnLaunch: DebugOptions.forceSignOutOnLaunch)

        guard let user = authViewModel.currentUser else {
            bootState = .needsLogin
            return
        }

        bootState = authViewModel.resolvedRole == nil ? .resolvingRole : .authenticated(user: user)
    }
}
