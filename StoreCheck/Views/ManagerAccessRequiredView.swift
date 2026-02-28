import SwiftUI

struct ManagerAccessRequiredView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text("Manager Access Required")
                .font(.title3.bold())
                .foregroundStyle(DS.Colors.textPrimary)
            Text(authViewModel.managerAccessMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.background.ignoresSafeArea())
    }
}
