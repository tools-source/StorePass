import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appContainer: AppContainer

    var body: some View {
        RootContentView(authService: appContainer.authService, roleProfileRepository: appContainer.roleProfileRepository)
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

    init(authService: AuthService, roleProfileRepository: RoleProfileRepositoryProtocol) {
        _authViewModel = StateObject(wrappedValue: AuthViewModel(authService: authService, roleProfileRepository: roleProfileRepository))
    }

    var body: some View {
        ZStack {
            AppBackground()

            Group {
                switch bootState {
                case .launching:
                    LaunchingView()
                        .transition(.opacity)

                case .needsLogin:
                    LoginView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))

                case .authenticated(let user):
                    if authViewModel.showManagerAccessRequired {
                        ManagerAccessRequiredView()
                            .transition(.opacity)
                    } else {
                        switch user.role {
                        case .manager:
                            ManagerHomeView(container: appContainer)
                                .transition(.opacity)
                        case .employee:
                            EmployeeTabView(container: appContainer)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .frame(maxWidth: DS.Metrics.maxReadableWidth)
        }
        .environmentObject(authViewModel)
        .task { await boot() }
        .animation(.easeInOut(duration: 0.22), value: stateToken)
        .onChange(of: authViewModel.authState) { _, newState in
            if case .signedOut = newState {
                bootState = .needsLogin
            }
        }
        .onChange(of: authViewModel.currentUser) { _, user in
            guard let user else {
                bootState = .needsLogin
                return
            }
            bootState = .authenticated(user: user)
        }
    }

    private var stateToken: Int {
        switch bootState {
        case .launching:
            return 0
        case .needsLogin:
            return 1
        case .authenticated:
            return 2
        }
    }

    private func boot() async {
        guard case .launching = bootState else { return }

        await authViewModel.restoreSession(forceSignOutOnLaunch: DebugOptions.forceSignOutOnLaunch)

        if let user = authViewModel.currentUser {
            bootState = .authenticated(user: user)
        } else {
            bootState = .needsLogin
        }
    }
}

private struct LaunchingView: View {
    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Spacer(minLength: 0)

            CardView {
                VStack(spacing: DS.Spacing.m) {
                    Image(systemName: "building.2.crop.circle.fill")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(DS.Colors.primary)

                    VStack(spacing: DS.Spacing.xs) {
                        Text("StorePass")
                            .font(DS.Typography.hero)
                            .foregroundStyle(DS.Colors.textPrimary)

                        Text("Secure attendance for managers and teams")
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .multilineTextAlignment(.center)

                    ProgressView("Preparing your workspace")
                        .tint(DS.Colors.primary)
                        .font(DS.Typography.caption)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.l)
    }
}
