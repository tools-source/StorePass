import CloudKit
import SwiftUI

struct AccountSettingsView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel

    @State private var editedName = ""
    @State private var isSavingName = false
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var cloudStatusMessage = "Checking iCloud status..."

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
                Text("This disables your account, removes active memberships, and signs you out.")
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

                Button(isDeletingAccount ? "Deleting..." : "Delete Account", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(isDeletingAccount)
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
                CKContainer.default().accountStatus { status, error in
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
}

struct EmployeeSettingsView: View {
    var body: some View {
        AccountSettingsView()
    }
}
