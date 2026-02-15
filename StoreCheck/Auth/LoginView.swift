import SwiftUI

struct LoginView: View {
    @StateObject private var viewModel: LoginViewModel

    init(role: UserRole) {
        _viewModel = StateObject(wrappedValue: LoginViewModel(role: role, authService: AppContainer.shared.authService))
    }

    var body: some View {
        Form {
            TextField("Email", text: $viewModel.email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            SecureField("Password", text: $viewModel.password)
            if let err = viewModel.errorMessage {
                Text(err).foregroundStyle(.red)
            }
            Button(viewModel.isLoading ? "Signing in..." : "Sign In") {
                Task { await viewModel.login() }
            }
            .disabled(viewModel.isLoading)
        }
        .navigationTitle(viewModel.role == .employee ? "Employee Login" : "Manager Login")
    }
}
