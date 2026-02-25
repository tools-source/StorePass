import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import GoogleSignIn
import Security
import SwiftUI
import UIKit

// What changed:
// - Added delete-account reauth retry flow for Apple/Google users.
// - Added targeted delete-account stage logging and resilient callable error parsing.

struct AccountSettingsView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @StateObject private var viewModel = AccountSettingsViewModel()
    @State private var showDeleteConfirmation = false
    @State private var showReauthSheet = false
    @State private var showEditNameSheet = false
    @State private var pendingDeleteRole: UserRole?
    @State private var deleteTask: Task<Void, Never>?
    @State private var editedNameDraft = ""
    @State private var localNameOverride: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(displayName)
                            .foregroundStyle(.secondary)

                        if viewModel.canEditAppleName {
                            Button("Edit") {
                                editedNameDraft = displayName
                                showEditNameSheet = true
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    LabeledContent("Email", value: authViewModel.currentUser?.email ?? "No email")
                    LabeledContent("Role", value: authViewModel.currentUser?.role.rawValue.capitalized ?? "Unknown")
                }

                Section("Account") {
                    Button("Sign Out", role: .destructive) {
                        Task { await authViewModel.signOut() }
                    }

                    Button("Delete Account", role: .destructive) {
                        guard !viewModel.isDeleting else { return }
                        showDeleteConfirmation = true
                    }
                    .disabled(viewModel.isDeleting || viewModel.isDeletingAccount)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.Colors.background)
            .navigationTitle("Settings")
            .alert("Delete account permanently?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    startDeleteTask {
                        let role = authViewModel.currentUser?.role
                        pendingDeleteRole = role
                        if role == .manager {
                            showReauthSheet = true
                        } else {
                            await viewModel.deleteAccount(role: role)
                            if viewModel.needsReauthentication {
                                showReauthSheet = true
                            } else if viewModel.errorMessage == nil {
                                await authViewModel.signOut()
                            }
                        }
                    }
                }
            } message: {
                Text("This deletes your profile, unlinks memberships, and removes login access.")
            }
            .sheet(isPresented: $showReauthSheet) {
                ReauthenticateSheet(viewModel: viewModel) {
                    showReauthSheet = false
                    startDeleteTask {
                        if pendingDeleteRole == .manager {
                            await viewModel.deleteManagerAccountFlow()
                        } else {
                            await viewModel.deleteAccountAfterReauth(role: pendingDeleteRole)
                        }
                        if viewModel.errorMessage == nil {
                            await authViewModel.signOut()
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showEditNameSheet) {
                NavigationStack {
                    Form {
                        TextField("Name", text: $editedNameDraft)
                    }
                    .navigationTitle("Edit Name")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showEditNameSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                Task {
                                    let trimmed = editedNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let ok = await viewModel.updateName(trimmed)
                                    if ok {
                                        localNameOverride = trimmed
                                        showEditNameSheet = false
                                    }
                                }
                            }
                            .disabled(!canSaveEditedName)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .alert("Settings", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { _ in viewModel.errorMessage = nil })) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onAppear {
                localNameOverride = authViewModel.currentUser?.name
                viewModel.refreshCanEditAppleName()
            }
            .onChange(of: authViewModel.currentUser?.name) { _, newValue in
                if let newValue {
                    localNameOverride = newValue
                }
            }
        }
    }

    private var displayName: String {
        localNameOverride ?? authViewModel.currentUser?.name ?? "StorePass User"
    }

    private var canSaveEditedName: Bool {
        let trimmed = editedNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != displayName
    }

    private func startDeleteTask(_ operation: @escaping @MainActor () async -> Void) {
        guard deleteTask == nil, !viewModel.isDeleting else { return }
        deleteTask = Task { @MainActor in
            defer { deleteTask = nil }
            await operation()
        }
    }
}

private struct ReauthenticateSheet: View {
    @ObservedObject var viewModel: AccountSettingsViewModel
    let onSuccess: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Re-authenticate to continue")
                    .font(.headline)
                Text("For security, please sign in again before deleting your account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if viewModel.selectedProviderForReauth == "apple.com" {
                    SignInWithAppleButton(.signIn) { request in
                        viewModel.prepareAppleReauthRequest(request)
                    } onCompletion: { result in
                        Task {
                            let ok = await viewModel.handleAppleReauthResult(result)
                            if ok {
                                onSuccess()
                            }
                        }
                    }
                    .frame(height: 44)
                    .cornerRadius(8)
                } else if viewModel.selectedProviderForReauth == "google.com" {
                    Button {
                        Task {
                            let ok = await viewModel.reauthenticateWithGoogle()
                            if ok {
                                onSuccess()
                            }
                        }
                    } label: {
                        Text("Continue with Google")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Unsupported sign-in provider. Please sign out and sign back in, then retry.")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if viewModel.isDeleting || viewModel.isDeletingAccount {
                    ProgressView("Working…")
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Verify Identity")
            .onAppear {
                viewModel.prepareProviderForReauth()
            }
        }
    }
}

struct EmployeeSettingsView: View {
    var body: some View {
        AccountSettingsView()
    }
}

@MainActor
final class AccountSettingsViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var selectedProviderForReauth: String?
    @Published var isDeleting = false
    @Published var isDeletingAccount = false
    @Published var needsReauthentication = false
    @Published var canEditAppleName = false
    private var deleteAccountTask: Task<Void, Never>? = nil
    private let cloudFunctions = CloudFunctionsService()
    private var appleReauthNonce: String?
    private let functions = Functions.functions(region: "us-central1")
    private let firestore = Firestore.firestore()

    private var auth: Auth {
        FirebaseBootstrap.assertConfigured(context: "AccountSettingsViewModel.auth")
        return Auth.auth()
    }

    private var firebaseApp: FirebaseApp {
        FirebaseBootstrap.assertConfigured(context: "AccountSettingsViewModel.firebaseApp")
        guard let app = FirebaseApp.app() else {
            fatalError("Firebase app is unexpectedly unavailable.")
        }
        return app
    }

    func prepareProviderForReauth() {
        guard let user = auth.currentUser else {
            selectedProviderForReauth = nil
            return
        }
        let providers = user.providerData.map(\.providerID)
        print("[DeleteAccount][PROVIDER] providers=\(providers)")
        if providers.contains("apple.com") {
            selectedProviderForReauth = "apple.com"
        } else if providers.contains("google.com") {
            selectedProviderForReauth = "google.com"
        } else {
            selectedProviderForReauth = providers.first
        }
    }

    func refreshCanEditAppleName() {
        let providerIds = auth.currentUser?.providerData.map(\.providerID) ?? []
        canEditAppleName = providerIds.contains("apple.com")
    }

    func updateName(_ newName: String) async -> Bool {
        guard let currentUser = auth.currentUser else {
            errorMessage = "You must be signed in."
            return false
        }

        do {
            try await firestore.collection("users").document(currentUser.uid).setData([
                "name": newName,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
            print("[Settings][NameUpdate] success uid=\(currentUser.uid)")
            errorMessage = nil
            return true
        } catch {
            print("[Settings][NameUpdate] failure uid=\(currentUser.uid) error=\(error.localizedDescription)")
            errorMessage = "We couldn't update your name right now. Please try again."
            return false
        }
    }

    func deleteManagerAccountFlow() async {
        guard let currentUser = auth.currentUser else {
            errorMessage = "You must be signed in."
            return
        }
        guard !isDeleting else {
            print("[DeleteAccount] stage=skip_duplicate uid=\(currentUser.uid) provider=\(providerForCurrentUser())")
            return
        }

        print("[DeleteAccount][START] uid=\(currentUser.uid)")
        isDeleting = true
        defer { isDeleting = false }

        do {
            _ = try await cloudFunctions.deleteManagerAccount()
            print("[DeleteAccount][FUNCTION_OK]")

            do {
                try await currentUser.delete()
                print("[DeleteAccount][AUTH_DELETE_OK]")
            } catch {
                let nsError = error as NSError
                if nsError.domain == AuthErrorDomain,
                   nsError.code == AuthErrorCode.userNotFound.rawValue {
                    print("[DeleteAccount][AUTH_DELETE_SKIPPED] user already removed by backend")
                } else {
                    throw error
                }
            }
            errorMessage = nil
        } catch {
            logDeleteAccountError(error)
            errorMessage = userFacingDeleteError(error)
        }
    }

    func prepareAppleReauthRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString(length: 32)
        appleReauthNonce = nonce
        request.requestedScopes = []
        request.nonce = sha256(nonce)
    }

    func handleAppleReauthResult(_ result: Result<ASAuthorization, Error>) async -> Bool {
        do {
            guard case .success(let authorization) = result,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = appleReauthNonce,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8),
                  let currentUser = auth.currentUser else {
                throw NSError(domain: "StorePass", code: 9001, userInfo: [NSLocalizedDescriptionKey: "Apple re-authentication failed."])
            }

            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: nonce,
                fullName: nil
            )
            _ = try await currentUser.reauthenticate(with: firebaseCredential)
            print("[DeleteAccount][REAUTH_OK]")
            return true
        } catch {
            logDeleteAccountError(error)
            errorMessage = userFacingDeleteError(error)
            return false
        }
    }

    func reauthenticateWithGoogle() async -> Bool {
        do {
            guard let currentUser = auth.currentUser else {
                throw NSError(domain: "StorePass", code: 9002, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
            }
            guard let clientID = firebaseApp.options.clientID else {
                throw NSError(domain: "StorePass", code: 9003, userInfo: [NSLocalizedDescriptionKey: "Firebase is not configured."])
            }
            guard let presenter = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?.rootViewController else {
                throw NSError(domain: "StorePass", code: 9004, userInfo: [NSLocalizedDescriptionKey: "Unable to present Google sign-in."])
            }

            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else {
                throw NSError(domain: "StorePass", code: 9005, userInfo: [NSLocalizedDescriptionKey: "Google ID token is missing."])
            }

            let firebaseCredential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            _ = try await currentUser.reauthenticate(with: firebaseCredential)
            print("[DeleteAccount][REAUTH_OK]")
            return true
        } catch {
            logDeleteAccountError(error)
            errorMessage = userFacingDeleteError(error)
            return false
        }
    }

    func deleteAccount(role: UserRole?) async {
        await executeDeleteAccount(role: role, allowReauthPrompt: true)
    }

    func deleteAccountAfterReauth(role: UserRole?) async {
        await executeDeleteAccount(role: role, allowReauthPrompt: false)
    }

    @MainActor
    private func executeDeleteAccount(role: UserRole?, allowReauthPrompt: Bool) async {
        _ = allowReauthPrompt

        guard let currentUser = auth.currentUser else {
            errorMessage = "You must be signed in."
            return
        }

        // ✅ Single-flight guard (stronger than booleans)
        if deleteAccountTask != nil {
            print("[DeleteAccount] stage=skip_duplicate_task uid=\(currentUser.uid) provider=\(providerForCurrentUser())")
            return
        }

        // set UI flags immediately (main actor)
        isDeleting = true
        isDeletingAccount = true

        let provider = providerForCurrentUser()
        logDeleteAccountStage("start", uid: currentUser.uid, provider: provider)

        let uid = currentUser.uid

        deleteAccountTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isDeleting = false
                    self.isDeletingAccount = false
                    self.deleteAccountTask = nil
                }
            }

            do {
                var payload: [String: Any] = ["mode": "cleanup_memberships"]
                let roleValue: Any = role?.rawValue ?? NSNull()
                payload["role"] = roleValue
                print("[DeleteAccount] role_debug rawValue=\(String(describing: role?.rawValue)) roleValueType=\(type(of: roleValue))")

                _ = try await self.callable(
                    name: "deleteMyAccount",
                    payload: payload
                )

                await MainActor.run {
                    self.logDeleteAccountStage("deleteMyAccount_ok", uid: uid, provider: provider)
                    self.needsReauthentication = false
                    self.errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.logDeleteAccountError(error)
                    self.errorMessage = self.userFacingDeleteError(error)
                }
            }
        }

        // wait for completion if caller expects it
        await deleteAccountTask?.value
    }

    private func logDeleteAccountStage(_ stage: String, uid: String, provider: String, error: Error? = nil) {
        if let error {
            let nsError = error as NSError
            print("[DeleteAccount] stage=\(stage) uid=\(uid) provider=\(provider) errorDomain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)")
            return
        }
        print("[DeleteAccount] stage=\(stage) uid=\(uid) provider=\(provider) errorDomain=none code=0 message=ok")
    }

    private func logDeleteAccountError(_ error: Error) {
        let ns = error as NSError
        let domain = ns.domain
        let code = ns.code
        let localized = ns.localizedDescription
        let details = ns.userInfo["details"] ?? ns.userInfo["data"] ?? ns.userInfo

        print("[DeleteAccount] stage=error uid=\(auth.currentUser?.uid ?? "nil") provider=\(providerForCurrentUser()) errorDomain=\(domain) code=\(code) message=\(localized)")
        print("[DeleteAccount][CLIENT_FAIL] domain=\(domain) code=\(code) message=\(localized) details=\(details) userInfo=\(ns.userInfo)")
    }

    private func userFacingDeleteError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "com.firebase.functions" || nsError.domain == "FunctionsErrorDomain" {
            return "Could not delete account data right now. Please try again."
        }
        if nsError.domain == AuthErrorDomain,
           nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
            return "For security, please sign in again and retry account deletion."
        }
        return nsError.localizedDescription
    }

    private func providerForCurrentUser() -> String {
        guard let user = auth.currentUser else { return "unknown" }
        let providerIds = user.providerData.map(\.providerID)
        if providerIds.contains("apple.com") { return "apple.com" }
        if providerIds.contains("google.com") { return "google.com" }
        if providerIds.contains("password") { return "password" }
        return providerIds.first ?? "unknown"
    }

    private func callable(name: String, payload: [String: Any]) async throws -> [String: Any] {
        print("[DeleteAccount] callable_request name=\(name) region=us-central1 payload=\(payload)")
        do {
            let callable = functions.httpsCallable(name)
            let result = try await callable.call(payload)
            let responseKeys = (result.data as? [String: Any])?.keys.sorted() ?? []
            print("[DeleteAccount] callable_response name=\(name) responseKeys=\(responseKeys) data=\(String(describing: result.data))")
            return result.data as? [String: Any] ?? [:]
        } catch {
            logDeleteAccountError(error)
            throw error
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var randomBytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            if status != errSecSuccess {
                fatalError("Unable to generate nonce")
            }

            for byte in randomBytes where remaining > 0 {
                if byte < charset.count {
                    result.append(charset[Int(byte)])
                    remaining -= 1
                }
            }
        }

        return result
    }

    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
