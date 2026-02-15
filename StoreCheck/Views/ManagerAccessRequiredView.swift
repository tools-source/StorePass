import SwiftUI

struct ManagerAccessRequiredView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
            Text("Manager Access Required")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("This account is not provisioned in /managers. Sign in as Employee or ask an admin for manager access.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Colors.background.ignoresSafeArea())
    }
}
