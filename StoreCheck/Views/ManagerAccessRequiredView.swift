import SwiftUI

struct ManagerAccessRequiredView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 46))
                .foregroundStyle(.yellow)
            Text("Role mismatch")
                .font(.title3.bold())
            Text(authViewModel.managerAccessMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Sign out") { Task { await authViewModel.signOut() } }
                .buttonStyle(DestructiveButtonStyle())
            Button("Back to Sign in") {
                authViewModel.signInNoticeMessage = nil
                Task { await authViewModel.signOut() }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.background.ignoresSafeArea())
    }
}
