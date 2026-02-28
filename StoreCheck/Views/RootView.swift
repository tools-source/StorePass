import FirebaseAuth
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
    @StateObject private var appLockViewModel = AppLockViewModel()
    @State private var bootState: BootState = .launching
    @State private var showAppLockPrompt = false
    @State private var didEnterBackground = false
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    @AppStorage("didPromptForAppLock") private var didPromptForAppLock = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appContainer: AppContainer

    private let biometricAuthService = BiometricAuthService()

    init(authService: AuthService, roleProfileRepository: RoleProfileRepositoryProtocol) {
        _authViewModel = StateObject(wrappedValue: AuthViewModel(authService: authService, roleProfileRepository: roleProfileRepository))
    }

    var body: some View {
        Group {
            switch bootState {
            case .launching:
                loadingView
            case .needsLogin:
                if authViewModel.isRoleResolutionLoading {
                    loadingView
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
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                didEnterBackground = true
            case .active:
                guard didEnterBackground else { return }
                didEnterBackground = false
                appLockViewModel.onAppBecameActive(isUserSignedIn: authViewModel.currentUser != nil)
            default:
                break
            }
        }
        .onChange(of: appLockEnabled) { _, newValue in
            if !newValue {
                appLockViewModel.unlockForDisabledAppLock()
            }
        }
        .onChange(of: authViewModel.authState) { _, newState in
            if case .signedOut = newState {
                bootState = .needsLogin
                appLockViewModel.unlockForDisabledAppLock()
            }
        }
        .onChange(of: authViewModel.currentUser) { _, newUser in
            guard let newUser else {
                bootState = .needsLogin
                appLockViewModel.unlockForDisabledAppLock()
                return
            }

            let cameFromLoginFlow: Bool
            if case .needsLogin = bootState {
                cameFromLoginFlow = true
            } else {
                cameFromLoginFlow = false
            }

            bootState = .authenticated(user: newUser)

            if cameFromLoginFlow,
               !didPromptForAppLock,
               biometricAuthService.biometricType() != .none,
               shouldOfferAppLockForCurrentProvider() {
                showAppLockPrompt = true
            }
        }
        .alert("Enable Face ID to unlock the app?", isPresented: $showAppLockPrompt) {
            Button("Not Now", role: .cancel) {
                appLockEnabled = false
                didPromptForAppLock = true
            }
            Button("Enable") {
                appLockEnabled = true
                didPromptForAppLock = true
            }
        } message: {
            Text("You can change this later in Settings.")
        }
        .sheet(isPresented: $authViewModel.shouldShowAppleNamePrompt) {
            AppleNamePromptSheet(
                name: $authViewModel.pendingNameUpdate,
                onSave: { Task { await authViewModel.saveAppleDisplayName() } }
            )
            .presentationDetents([.medium])
            .interactiveDismissDisabled()
        }
        .overlay {
            if authViewModel.currentUser != nil, appLockEnabled, appLockViewModel.isLocked {
                AppLockOverlayView(
                    biometricType: biometricAuthService.biometricType(),
                    isAuthenticating: appLockViewModel.isAuthenticating,
                    lastAuthFailed: appLockViewModel.lastAuthFailed,
                    onTryAgain: {
                        Task {
                            await appLockViewModel.unlock()
                        }
                    }
                )
            }
        }
    }

    private func shouldOfferAppLockForCurrentProvider() -> Bool {
        guard let providers = Auth.auth().currentUser?.providerData.map(\.providerID) else {
            return false
        }

        return providers.contains("apple.com") || providers.contains("google.com")
    }

    @ViewBuilder
    private var loadingView: some View {
        ProgressView("Loading account")
            .tint(.white)
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
