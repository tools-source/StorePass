import SwiftUI

struct EmployeeSetupRequiredView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @State private var selectedRole: UserRole = .employee

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(DS.Colors.primary)
            Text("Complete Account Setup")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Choose the role for this account to finish the first-time setup.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Picker("Role", selection: $selectedRole) {
                Text("Employee").tag(UserRole.employee)
                Text("Manager").tag(UserRole.manager)
            }
            .pickerStyle(.segmented)

            Button("Continue") {
                Task { await authViewModel.completeSetup(with: selectedRole) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(authViewModel.isLoading)

            if authViewModel.isLoading {
                ProgressView().tint(.white)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.background.ignoresSafeArea())
    }
}
