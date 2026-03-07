import SwiftUI

struct ManagerAccessRequiredView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel

    var body: some View {
        ZStack {
            AppBackground()

            VStack {
                CardView {
                    VStack(spacing: DS.Spacing.m) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(DS.Colors.warning)

                        Text("Manager Access Required")
                            .font(DS.Typography.title)
                            .foregroundStyle(DS.Colors.textPrimary)

                        Text(authViewModel.managerAccessMessage)
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .multilineTextAlignment(.center)

                        VStack(spacing: DS.Spacing.s) {
                            Button("Sign out") {
                                Task { await authViewModel.signOut() }
                            }
                            .buttonStyle(DestructiveButtonStyle())

                            Button("Back to Sign in") {
                                authViewModel.signInNoticeMessage = nil
                                Task { await authViewModel.signOut() }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: DS.Metrics.maxReadableWidth)
                .padding(DS.Spacing.l)
            }
        }
    }
}
