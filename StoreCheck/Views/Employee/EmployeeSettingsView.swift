import SwiftUI

struct AccountSettingsView: View {
    private enum FormField: Hashable {
        case displayName
    }

    @EnvironmentObject private var authViewModel: AuthViewModel

    @State private var editedName = ""
    @State private var isSavingName = false
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @FocusState private var focusedField: FormField?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DS.Spacing.m) {
                        profileCard
                        updateNameCard
                        accountActionsCard
                    }
                    .frame(maxWidth: DS.Metrics.maxReadableWidth)
                    .padding(.horizontal, DS.Spacing.m)
                    .padding(.vertical, DS.Spacing.m)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
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
                    .submitLabel(.done)
                    .focused($focusedField, equals: .displayName)
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
        focusedField = nil
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

}

struct EmployeeSettingsView: View {
    var body: some View {
        AccountSettingsView()
    }
}
