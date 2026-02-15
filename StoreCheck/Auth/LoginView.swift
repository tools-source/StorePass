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

            Picker("Mode", selection: Binding(get: {
                viewModel.requestedRole ?? .employee
            }, set: { newRole in
                viewModel.requestedRole = newRole
            })) {
                Text("Employee").tag(UserRole.employee)
                Text("Manager").tag(UserRole.manager)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            VStack(spacing: 12) {
                Button("Continue with Google") {
                    Task { await viewModel.signInWithGoogle(requestedRole: viewModel.requestedRole ?? .employee) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.isLoading)

                SignInWithAppleButton(.signIn) { request in
                    viewModel.prepareAppleSignInRequest(request)
                } onCompletion: { result in
                    viewModel.handleAppleSignInResult(result, requestedRole: viewModel.requestedRole ?? .employee)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(maxWidth: 375)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            }
            .frame(maxWidth: 420)

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
        .onAppear {
            if viewModel.requestedRole == nil {
                viewModel.requestedRole = .employee
            }
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            showError = newValue != nil
        }
    }
}
