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
        Group {
            switch bootState {
            case .launching:
                ProgressView("Loading account")
                    .tint(.white)
            case .needsLogin:
                if authViewModel.isRoleResolutionLoading {
                    ProgressView("Loading account")
                        .tint(.white)
                }
                else {
                    LoginView()
                }
            case .authenticated(let user):
                switch user.role {
                case .manager:
                    ManagerHomeView(container: appContainer)
                case .employee:
                    EmployeeTabView(container: appContainer)
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

            bootState = .authenticated(user: newUser)
        }
        .sheet(isPresented: $authViewModel.shouldShowAppleNamePrompt) {
            AppleNamePromptSheet(
                name: $authViewModel.pendingNameUpdate,
                onSave: { Task { await authViewModel.saveAppleDisplayName() } }
            )
            .presentationDetents([.medium])
            .interactiveDismissDisabled()
        }
    }

    private func boot() async {
        guard case .launching = bootState else { return }

        await authViewModel.restoreSession(forceSignOutOnLaunch: DebugOptions.forceSignOutOnLaunch)

        guard let user = authViewModel.currentUser else {
            bootState = .needsLogin
            return
        }

        bootState = .authenticated(user: user)
    }
}

private struct AppleNamePromptSheet: View {
    @Binding var name: String
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Confirm your name")
                    .font(.headline)
                Text("Apple may hide your profile details later. Confirm your display name now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Full name", text: $name)
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button("Save") {
                    onSave()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding()
            .navigationTitle("Profile")
        }
    }
}
