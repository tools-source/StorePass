import AuthenticationServices
import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel = AuthViewModel(authService: AppContainer.shared.authService as! AuthService)
    @State private var showError = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "building.2.crop.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .foregroundStyle(.blue)

            Text("StoreCheck")
                .font(.largeTitle.bold())

            VStack(spacing: 12) {
                Button {
                    Task { await viewModel.signInWithGoogle() }
                } label: {
                    Label("Continue with Google", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)

                SignInWithAppleButton(.signIn) { request in
                    viewModel.prepareAppleSignInRequest(request)
                } onCompletion: { result in
                    viewModel.handleAppleSignInResult(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: 375)   // <= important
                .frame(height: 50)
                .disabled(viewModel.isLoading)
            }

            if viewModel.isLoading {
                ProgressView("Signing in...")
            }
            Spacer()
        }
        .padding(24)
        .alert("Sign-In Error", isPresented: $showError, actions: {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        }, message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        })
        .onChange(of: viewModel.errorMessage) { newValue in
            showError = newValue != nil
        }
    }
}
