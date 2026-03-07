import CloudKit
import SwiftUI

struct AccountSettingsView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @EnvironmentObject private var appContainer: AppContainer

    @State private var editedName = ""
    @State private var isSavingName = false
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var cloudStatusMessage = "Checking iCloud status..."
    @State private var diagnosticsMessage = ""
    @State private var isRunningDiagnostics = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.m) {
                        profileCard
                        updateNameCard
                        cloudStatusCard
                        accountActionsCard
                    }
                    .frame(maxWidth: DS.Metrics.maxReadableWidth)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.m)
                }
            }
            .navigationTitle("Settings")
            .alert("Delete account permanently?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text("This permanently deletes your account data, memberships, and check-ins, then signs you out.")
            }
            .alert("Settings", isPresented: Binding(get: { authViewModel.errorMessage != nil }, set: { _ in authViewModel.errorMessage = nil })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(authViewModel.errorMessage ?? "")
            }
            .task {
                editedName = authViewModel.currentUser?.name ?? ""
                await refreshCloudStatus()
            }
        }
    }

    private var profileCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Profile", subtitle: "Your account identity", icon: "person.crop.square")

                KeyValueRow(title: "Name", value: authViewModel.currentUser?.name ?? "StorePass User")
                KeyValueRow(title: "Email", value: authViewModel.currentUser?.email ?? "Not shared")
                KeyValueRow(title: "Role", value: authViewModel.currentUser?.role.rawValue.capitalized ?? "Unknown")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var updateNameCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Display Name", subtitle: "Used across attendance records", icon: "pencil")

                TextField("Display name", text: $editedName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(.horizontal, DS.Spacing.s)
                    .frame(height: DS.Metrics.rowHeight)
                    .background(DS.Colors.elevated.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(isSavingName ? "Saving..." : "Save Name") {
                    Task { await saveName() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSavingName || editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cloudStatusCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "System Status", subtitle: "Required for app features", icon: "icloud")

                Text(cloudStatusMessage)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                #if DEBUG
                Divider()

                Text("CloudKit Diagnostics")
                    .font(DS.Typography.headline)
                    .foregroundStyle(DS.Colors.textPrimary)

                Text("Container: \(appContainer.cloudKitService.container.containerIdentifier ?? "default")")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textSecondary)

                Button(isRunningDiagnostics ? "Running diagnostics..." : "Run Integrity Check") {
                    Task { await runDiagnostics() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isRunningDiagnostics)
                .accessibilityIdentifier("run_cloudkit_diagnostics_button")

                if !diagnosticsMessage.isEmpty {
                    Text(diagnosticsMessage)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                #endif
            }
        }
    }

    private var accountActionsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ScreenHeader(title: "Account Actions", subtitle: "Security and lifecycle", icon: "shield.lefthalf.filled")

                Button("Sign Out", role: .destructive) {
                    Task { await authViewModel.signOut() }
                }
                .buttonStyle(DestructiveButtonStyle())
                .accessibilityIdentifier("settings_sign_out_button")

                Button(isDeletingAccount ? "Deleting..." : "Delete Account", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(isDeletingAccount)
                .accessibilityIdentifier("settings_delete_account_button")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveName() async {
        isSavingName = true
        defer { isSavingName = false }

        do {
            try await authViewModel.updateDisplayName(editedName)
        } catch {
            authViewModel.errorMessage = error.localizedDescription
        }
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            try await authViewModel.deleteCurrentAccount()
        } catch {
            authViewModel.errorMessage = error.localizedDescription
        }
    }

    private func refreshCloudStatus() async {
        do {
            let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKAccountStatus, Error>) in
                appContainer.cloudKitService.container.accountStatus { status, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: status)
                    }
                }
            }

            switch status {
            case .available:
                cloudStatusMessage = "iCloud connected"
            case .noAccount:
                cloudStatusMessage = "iCloud is signed out. Core app features are unavailable."
            case .restricted:
                cloudStatusMessage = "iCloud access is restricted on this device."
            case .couldNotDetermine:
                cloudStatusMessage = "Could not verify iCloud account status."
            case .temporarilyUnavailable:
                cloudStatusMessage = "iCloud is temporarily unavailable."
            @unknown default:
                cloudStatusMessage = "Unknown iCloud status."
            }
        } catch {
            cloudStatusMessage = "Unable to check iCloud status right now."
        }
    }

    private func runDiagnostics() async {
        #if DEBUG
        guard let user = authViewModel.currentUser else {
            diagnosticsMessage = "No signed-in user."
            return
        }

        isRunningDiagnostics = true
        defer { isRunningDiagnostics = false }
        let report = await appContainer.cloudKitSanityChecker.run(currentUserId: user.id)
        diagnosticsMessage = report.renderedText
        #endif
    }

    private func accountStatusText(_ status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "available"
        case .noAccount:
            return "noAccount"
        case .restricted:
            return "restricted"
        case .couldNotDetermine:
            return "couldNotDetermine"
        case .temporarilyUnavailable:
            return "temporarilyUnavailable"
        @unknown default:
            return "unknown"
        }
    }
}

struct EmployeeSettingsView: View {
    var body: some View {
        AccountSettingsView()
    }
}
