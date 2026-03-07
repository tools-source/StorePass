import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @State private var showError = false

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: DS.Spacing.l) {
                    hero
                    roleAndAuthCard
                    valuePropsCard

                    if let notice = viewModel.signInNoticeMessage {
                        BannerView(text: notice, isError: true)
                    }
                }
                .frame(maxWidth: DS.Metrics.maxReadableWidth)
                .padding(.horizontal, DS.Spacing.m)
                .padding(.vertical, DS.Spacing.l)
            }
        }
        .overlay {
            if viewModel.isLoading {
                LoadingOverlay(message: "Signing in with Apple...")
            }
        }
        .alert("Sign in", isPresented: $showError) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .onAppear {
            if viewModel.requestedRole == nil {
                viewModel.requestedRole = .employee
            }
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            showError = newValue != nil
        }
    }

    private var hero: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(DS.Colors.primaryGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("StorePass")
                            .font(DS.Typography.largeTitle)
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("Manager + Employee attendance")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }

                Text("Sign in with Apple to keep your account secure and synced across devices.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var roleAndAuthCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                ScreenHeader(
                    title: "Choose your role",
                    subtitle: "You can continue as Manager or Employee.",
                    icon: "person.2.badge.key"
                )

                HStack(spacing: DS.Spacing.s) {
                    roleTile(.manager, title: "Manager", detail: "Manage stores and attendance")
                    roleTile(.employee, title: "Employee", detail: "Check in/out and view history")
                }

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { _ in
                    guard let role = viewModel.requestedRole else { return }
                    Task { await viewModel.signInWithApple(requestedRole: role) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
                .disabled(viewModel.isLoading)

                Text("Google sign-in has been removed. Apple sign-in is required for all accounts.")
                    .font(DS.Typography.micro)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }

    private var valuePropsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("What you get")
                    .font(DS.Typography.headline)

                valuePropRow(icon: "icloud", text: "CloudKit sync between manager and employee")
                valuePropRow(icon: "person.crop.square", text: "Front-camera photo verification for check-in/out")
                valuePropRow(icon: "location.viewfinder", text: "Geo-fence validation with secure attendance records")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func roleTile(_ role: UserRole, title: String, detail: String) -> some View {
        let isSelected = (viewModel.requestedRole ?? .employee) == role

        return Button {
            viewModel.requestedRole = role
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(DS.Typography.headline)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(detail)
                    .font(DS.Typography.micro)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? DS.Colors.elevated : DS.Colors.card.opacity(0.7))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? DS.Colors.primary.opacity(0.35) : DS.Colors.separator, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func valuePropRow(icon: String, text: String) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 20)

            Text(text)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)

            Spacer(minLength: 0)
        }
    }
}
