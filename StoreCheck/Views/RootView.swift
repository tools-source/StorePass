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
            case .launching:
                ProgressView("Restoring session")
                    .tint(.white)
            case .needsLogin:
                LoginView()
            case .authenticated(let user):
                switch user.role {
                case .manager:
                    ManagerTabView(container: appContainer)
                case .employee:
                    EmployeeTabView(container: appContainer)
                }
            }
        }
        .background(DS.Colors.background.ignoresSafeArea())
        .environmentObject(authViewModel)
        .task {
            await boot()
        }
        .onChange(of: authViewModel.authState) { _, newValue in
            guard case .signedOut = newValue else { return }
            bootState = .needsLogin
        }
        .onChange(of: authViewModel.currentUser) { _, newUser in
            if let newUser {
                bootState = .authenticated(user: newUser)
            }
        }
    }

    private func boot() async {
        guard case .launching = bootState else { return }

        #if DEBUG
        if DebugOptions.forceSignOutOnLaunch {
            print("[RootView] Debug force sign-out is enabled")
        }
        print("[RootView] boot start")
        #endif

        await authViewModel.restoreSession(forceSignOutOnLaunch: DebugOptions.forceSignOutOnLaunch)

        if let user = authViewModel.currentUser {
            #if DEBUG
            print("[RootView] boot complete: authenticated uid=\(user.id), role=\(user.role.rawValue)")
            #endif
            bootState = .authenticated(user: user)
        } else {
            #if DEBUG
            print("[RootView] boot complete: needs login")
            #endif
            bootState = .needsLogin
        }
    }
}
