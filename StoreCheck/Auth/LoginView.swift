import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @State private var showError = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(DS.Colors.primary)

            Text("StorePass")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            Text("Secure employee check-ins with geo validation")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $viewModel.requestedRole) {
                Text("Employee").tag(Optional(UserRole.employee))
                Text("Manager").tag(Optional(UserRole.manager))
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            VStack(spacing: 12) {
                Button("Continue with Google") {
                    guard let requestedRole = viewModel.requestedRole else { return }
                    Task { await viewModel.signInWithGoogle(requestedRole: requestedRole) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.isLoading || viewModel.requestedRole == nil)

                SignInWithAppleButton(.signIn) { request in
                    viewModel.prepareAppleSignInRequest(request)
                } onCompletion: { result in
                    guard let requestedRole = viewModel.requestedRole else { return }
                    viewModel.handleAppleSignInResult(result, requestedRole: requestedRole)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(maxWidth: 375)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .disabled(viewModel.isLoading || viewModel.requestedRole == nil)
            }
            .frame(maxWidth: 420)

            if let notice = viewModel.signInNoticeMessage {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.yellow.opacity(0.9), in: Capsule())
            }

            if viewModel.isLoading { ProgressView().tint(.white) }
            Spacer()
        }
        .padding(24)
        .background(DS.Colors.background.ignoresSafeArea())
        .alert("Sign in", isPresented: $showError) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            showError = newValue != nil
        }
    }
}
