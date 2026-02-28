import AuthenticationServices
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import GoogleSignIn
import SwiftUI
import UIKit

struct AccountSettingsView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @StateObject private var viewModel = AccountSettingsViewModel()
    @State private var showDeleteConfirmation = false
    @State private var showReauthSheet = false
    @State private var localNameOverride: String?
    @State private var showAppLockUnavailableAlert = false
    @State private var appLockUnavailableMessage = ""
    @AppStorage("appLockEnabled") private var appLockEnabled = false

    private let biometricAuthService = BiometricAuthService()

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    LabeledContent("Name", value: displayName)
                    LabeledContent("Email", value: authViewModel.currentUser?.email ?? "No email")
                    LabeledContent("Role", value: authViewModel.currentUser?.role.rawValue.capitalized ?? "Unknown")
                }

                Section("Security") {
                    Toggle(isOn: $appLockEnabled) {
                        Text("Use Face ID to unlock")
                    }
                    .onChange(of: appLockEnabled) { _, newValue in
                        guard newValue else { return }
                        guard biometricAuthService.biometricType() != .none else {
                            appLockEnabled = false
                            appLockUnavailableMessage = "Face ID / Touch ID is not available on this device."
                            showAppLockUnavailableAlert = true
                            return
                        }
                    }
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
                    Task {
                        await viewModel.deleteEmployeeAccountFlow()
                    }
                }
            } message: {
                Text("This deletes your profile, unlinks memberships, and removes login access.")
            }
            .sheet(isPresented: $showReauthSheet) {
                ReauthenticateSheet(viewModel: viewModel) {
                    showReauthSheet = false
                    Task {
                        await viewModel.deleteEmployeeAccountAfterReauthFlow()
                    }
                }
                .presentationDetents([.medium])
            }
            .alert("Settings", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { _ in viewModel.errorMessage = nil })) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("App Lock", isPresented: $showAppLockUnavailableAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(appLockUnavailableMessage)
            }
            .onAppear {
                localNameOverride = authViewModel.currentUser?.name
            }
            .onChange(of: authViewModel.currentUser?.name) { _, newValue in
                if let newValue {
                    localNameOverride = newValue
                }
            }
            .onChange(of: viewModel.needsReauthentication) { _, needsReauthentication in
                showReauthSheet = needsReauthentication
            }
            .onChange(of: viewModel.didCompleteEmployeeDeletion) { _, didCompleteEmployeeDeletion in
                guard didCompleteEmployeeDeletion else { return }
                Task {
                    await authViewModel.signOut()
                    await MainActor.run {
                        viewModel.didCompleteEmployeeDeletion = false
                    }
                }
            }
        }
    }

    private var displayName: String {
        localNameOverride ?? authViewModel.currentUser?.name ?? "StorePass User"
    }
}

private struct ReauthenticateSheet: View {
    @Environment(\.dismiss) private var dismiss
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
                    AppleReauthButton {
                        Task {
                            let ok = await viewModel.reauthenticateWithApple()
                            if ok {
                                onSuccess()
                            }
                        }
                    }
                    .frame(height: 50)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}


private struct AppleReauthButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .black)
        button.cornerRadius = 10
        button.addTarget(context.coordinator, action: #selector(Coordinator.didTap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func didTap() {
            action()
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
    @Published var didCompleteEmployeeDeletion = false
    private var deleteAccountTask: Task<Void, Never>? = nil
    private let cloudFunctions = CloudFunctionsService()
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
                try await currentUser.deleteAsync()
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
            _ = try await currentUser.reauthenticateAsync(with: firebaseCredential)
            print("[DeleteAccount][REAUTH_OK]")
            return true
        } catch {
            logDeleteAccountError(error)
            errorMessage = userFacingDeleteError(error)
            return false
        }
    }

    func reauthenticateWithApple() async -> Bool {
        do {
            guard let currentUser = auth.currentUser else {
                throw NSError(domain: "StorePass", code: 9010, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
            }

            let nonce = AuthService.randomNonceString()
            let appleAuthorization = try await AuthService.performAppleAuthorization(nonce: nonce)

            guard let idTokenString = String(data: appleAuthorization.identityToken, encoding: .utf8) else {
                throw NSError(domain: "StorePass", code: 9011, userInfo: [NSLocalizedDescriptionKey: "Unable to decode Apple identity token."])
            }

            let credential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: nil
            )

            _ = try await currentUser.reauthenticateAsync(with: credential)
            print("[DeleteAccount][REAUTH_OK] provider=apple.com")
            return true
        } catch {
            logDeleteAccountError(error)
            errorMessage = userFacingDeleteError(error)
            return false
        }
    }

    func deleteEmployeeAccountFlow() async {
        await executeEmployeeDeleteAccountFlow(allowReauthPrompt: true)
    }

    func deleteEmployeeAccountAfterReauthFlow() async {
        await executeEmployeeDeleteAccountFlow(allowReauthPrompt: false)
    }

    @MainActor
    private func executeEmployeeDeleteAccountFlow(allowReauthPrompt: Bool) async {
        guard let currentUser = auth.currentUser else {
            errorMessage = "You must be signed in."
            return
        }

        if deleteAccountTask != nil {
            print("[DeleteAccount] stage=skip_duplicate_task uid=\(currentUser.uid) provider=\(providerForCurrentUser())")
            return
        }

        isDeleting = true
        isDeletingAccount = true
        needsReauthentication = false
        didCompleteEmployeeDeletion = false

        let providerIDs = currentUser.providerData.map(\.providerID)
        let provider = providerForCurrentUser()
        printDeleteAccountDiagnostics()
        let uid = currentUser.uid
        let correlationId = UUID().uuidString
        logDeleteAccountStage("start", uid: uid, provider: provider, correlationId: correlationId)

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
                try await self.writeEmployeeDeletionRequest(uid: uid, providerIDs: providerIDs, correlationId: correlationId)
                await self.callDeleteMyAccountInBackground(uid: uid, provider: provider, correlationId: correlationId)
                try await self.deleteFirebaseAuthUser(uid: uid, provider: provider)
                await MainActor.run {
                    self.logDeleteAccountStage("delete_complete", uid: uid, provider: provider, correlationId: correlationId)
                    self.needsReauthentication = false
                    self.errorMessage = nil
                    self.didCompleteEmployeeDeletion = true
                }
            } catch {
                await MainActor.run {
                    self.logDeleteAccountError(error, correlationId: correlationId)
                }

                if allowReauthPrompt && self.isRequiresRecentLoginError(error) {
                    await MainActor.run {
                        self.needsReauthentication = true
                        self.prepareProviderForReauth()
                        self.errorMessage = nil
                        print("[DeleteAccount] correlationId=\(correlationId) stage=needs_reauth uid=\(uid) provider=\(self.selectedProviderForReauth ?? self.providerForCurrentUser())")
                    }
                    return
                }

                await MainActor.run {
                    self.errorMessage = self.userFacingDeleteError(error)
                }
            }
        }

        await deleteAccountTask?.value
    }

    private func writeEmployeeDeletionRequest(uid: String, providerIDs: [String], correlationId: String) async throws {
        let deletionRequestPayload: [String: Any] = [
            "uid": uid,
            "role": "employee",
            "providerIDs": providerIDs,
            "createdAt": FieldValue.serverTimestamp(),
            "status": "pending",
            "reason": "user_initiated",
            "correlationId": correlationId,
            "app": "employee"
        ]

        let userPendingDeletionPayload: [String: Any] = [
            "pendingDeletion": true,
            "pendingDeletionAt": FieldValue.serverTimestamp(),
            "pendingDeletionCorrelationId": correlationId,
            "isActive": false
        ]

        do {
            try await firestore.collection("deletionRequests").document(uid).setData(deletionRequestPayload, merge: true)
            print("[DeleteAccount] correlationId=\(correlationId) stage=deletion_request_written uid=\(uid) providerIDs=\(providerIDs)")
        } catch {
            print("[DeleteAccount] correlationId=\(correlationId) stage=deletion_request_write_failed uid=\(uid) providerIDs=\(providerIDs) error=\(error.localizedDescription)")
            throw error
        }

        do {
            try await firestore.collection("users").document(uid).setData(userPendingDeletionPayload, merge: true)
            print("[DeleteAccount] correlationId=\(correlationId) stage=user_pending_deletion_write_ok uid=\(uid) providerIDs=\(providerIDs)")
        } catch {
            print("[DeleteAccount] correlationId=\(correlationId) stage=user_pending_deletion_write_failed uid=\(uid) providerIDs=\(providerIDs) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func callDeleteMyAccountInBackground(uid: String, provider: String, correlationId: String) async {
        guard let currentUser = auth.currentUser else { return }

        do {
            print("[DeleteAccount] correlationId=\(correlationId) stage=refresh_token_start uid=\(uid) provider=\(provider)")
            _ = try await currentUser.getIDTokenForcingRefreshAsync(true)
            print("[DeleteAccount] correlationId=\(correlationId) stage=refresh_token_ok uid=\(uid) provider=\(provider)")

            let payload: [String: Any] = [
                "mode": "cleanup_memberships",
                "role": UserRole.employee.rawValue,
                "correlationId": correlationId
            ]
            let response = try await callable(name: "deleteMyAccount", payload: payload)
            print("[DeleteAccount] correlationId=\(correlationId) stage=deleteMyAccount_result uid=\(uid) provider=\(provider) response=\(response)")
        } catch {
            print("[DeleteAccount] correlationId=\(correlationId) stage=deleteMyAccount_non_blocking_error uid=\(uid) provider=\(provider) error=\(error.localizedDescription)")
        }
    }

    private func deleteFirebaseAuthUser(uid: String, provider: String) async throws {
        guard let currentUser = auth.currentUser else {
            throw NSError(domain: "StorePass", code: 9016, userInfo: [NSLocalizedDescriptionKey: "You must be signed in."])
        }
        do {
            try await currentUser.deleteAsync()
            logDeleteAccountStage("auth_delete_ok", uid: uid, provider: provider)
        } catch {
            let nsError = error as NSError
            if nsError.domain == AuthErrorDomain,
               nsError.code == AuthErrorCode.userNotFound.rawValue {
                logDeleteAccountStage("auth_delete_user_not_found", uid: uid, provider: provider)
                return
            }
            throw error
        }
    }

    private func printDeleteAccountDiagnostics() {
        let providerIDs = auth.currentUser?.providerData.map(\.providerID) ?? []
        let uid = auth.currentUser?.uid ?? "nil"
        print("[DeleteAccount][BEGIN] uid=\(uid) providerIDs=\(providerIDs)")
    }

    private func logDeleteAccountStage(_ stage: String, uid: String, provider: String, correlationId: String? = nil, error: Error? = nil) {
        let correlationSegment = "correlationId=\(correlationId ?? "none")"
        if let error {
            let nsError = error as NSError
            print("[DeleteAccount] \(correlationSegment) stage=\(stage) uid=\(uid) provider=\(provider) errorDomain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)")
            return
        }
        print("[DeleteAccount] \(correlationSegment) stage=\(stage) uid=\(uid) provider=\(provider) errorDomain=none code=0 message=ok")
    }

    private func logDeleteAccountError(_ error: Error, correlationId: String? = nil) {
        let ns = error as NSError
        let domain = ns.domain
        let code = ns.code
        let localized = ns.localizedDescription
        let details = ns.userInfo["details"] ?? ns.userInfo["data"] ?? ns.userInfo
        let correlationSegment = "correlationId=\(correlationId ?? "none")"

        print("[DeleteAccount] \(correlationSegment) stage=error uid=\(auth.currentUser?.uid ?? "nil") provider=\(providerForCurrentUser()) errorDomain=\(domain) code=\(code) message=\(localized)")
        print("[DeleteAccount][CLIENT_FAIL] \(correlationSegment) domain=\(domain) code=\(code) message=\(localized) userInfoKeys=\(Array(ns.userInfo.keys)) details=\(details) userInfo=\(ns.userInfo)")
    }

    private func isRequiresRecentLoginError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
            return true
        }

        let isFunctionsDomain = nsError.domain == FunctionsErrorDomain || nsError.domain == "com.firebase.functions"
        guard isFunctionsDomain else {
            return false
        }

        if nsError.localizedDescription.range(of: "requires recent login", options: .caseInsensitive) != nil {
            return true
        }

        return containsRequiresRecentLoginSignal(nsError.userInfo)
    }

    private func containsRequiresRecentLoginSignal(_ value: Any?) -> Bool {
        guard let value else { return false }

        if let number = value as? NSNumber,
           number.intValue == AuthErrorCode.requiresRecentLogin.rawValue {
            return true
        }

        if let string = value as? String {
            if string.range(of: "requires recent login", options: .caseInsensitive) != nil {
                return true
            }
            if Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) == AuthErrorCode.requiresRecentLogin.rawValue {
                return true
            }
            return false
        }

        if let dict = value as? [String: Any] {
            for key in ["code", "authCode", "authErrorCode", "errorCode"] {
                if containsRequiresRecentLoginSignal(dict[key]) {
                    return true
                }
            }
            for key in ["message", "error", "description"] {
                if containsRequiresRecentLoginSignal(dict[key]) {
                    return true
                }
            }
            return dict.values.contains(where: containsRequiresRecentLoginSignal)
        }

        if let array = value as? [Any] {
            return array.contains(where: containsRequiresRecentLoginSignal)
        }

        return false
    }

    private func userFacingDeleteError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "com.firebase.functions" || nsError.domain == "FunctionsErrorDomain" {
            return "Could not delete account data right now. Please try again."
        }
        if nsError.domain == AuthErrorDomain,
           nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
            if auth.currentUser?.providerData.map(\.providerID).contains("apple.com") == true {
                return "For security, please re-authenticate with Apple and retry account deletion."
            }
            return "For security, please sign in again and retry account deletion."
        }
        return nsError.localizedDescription
    }

    private func providerForCurrentUser() -> String {
        guard let user = auth.currentUser else { return "unknown" }
        let providerIds = user.providerData.map(\.providerID)
        if providerIds.contains("google.com") { return "google.com" }
        if providerIds.contains("apple.com") { return "apple.com" }
        return providerIds.first ?? "unknown"
    }

    private func callable(name: String, payload: [String: Any]) async throws -> [String: Any] {
        let uid = auth.currentUser?.uid ?? "nil"
        let providerIDs = auth.currentUser?.providerData.map(\.providerID) ?? []
        print("[DeleteAccount] callable_request uid=\(uid) providerIDs=\(providerIDs) name=\(name) region=us-central1 payload=\(payload)")
        do {
            let callable = functions.httpsCallable(name)
            let result = try await callable.call(payload)
            print("[DeleteAccount] callable_success uid=\(uid) providerIDs=\(providerIDs) name=\(name) region=us-central1 rawData=\(String(describing: result.data))")
            guard let data = result.data as? [String: Any] else {
                throw NSError(domain: "StorePass", code: 9017, userInfo: [NSLocalizedDescriptionKey: "Delete account function returned an invalid payload."])
            }
            return data
        } catch {
            let nsError = error as NSError
            print("[DeleteAccount] callable_error uid=\(uid) providerIDs=\(providerIDs) name=\(name) region=us-central1 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            throw error
        }
    }


}

extension User {
    func getIDTokenForcingRefreshAsync(_ forceRefresh: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            getIDTokenForcingRefresh(forceRefresh) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let token else {
                    continuation.resume(throwing: NSError(domain: "StorePass", code: 9013, userInfo: [NSLocalizedDescriptionKey: "Unable to refresh authentication token."]))
                    return
                }

                continuation.resume(returning: token)
            }
        }
    }

    func deleteAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delete { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: Void())
            }
        }
    }

    func reauthenticateAsync(with credential: AuthCredential) async throws -> AuthDataResult {
        try await withCheckedThrowingContinuation { continuation in
            reauthenticate(with: credential) { authResult, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let authResult else {
                    continuation.resume(throwing: NSError(domain: "StorePass", code: 9014, userInfo: [NSLocalizedDescriptionKey: "Unable to re-authenticate."]))
                    return
                }

                continuation.resume(returning: authResult)
            }
        }
    }
}
