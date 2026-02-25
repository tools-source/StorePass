import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @State private var showError = false
    @State private var showEmailAuth = false

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

                Button("Sign in with Email") {
                    showEmailAuth = true
                }
                .buttonStyle(PrimaryButtonStyle())
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
        .sheet(isPresented: $showEmailAuth) {
            EmailAuthView()
                .environmentObject(viewModel)
        }
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

private struct EmailAuthView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                // Firebase Console prerequisite:
                // Authentication -> Sign-in method -> enable Email/Password provider.
                Section("Account") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }

                Section {
                    Button("Sign In") {
                        Task {
                            await viewModel.signInWithEmail(email: normalizedEmail, password: password)
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(!canSubmit)

                    Button("Create Account") {
                        guard let requestedRole = viewModel.requestedRole else { return }
                        Task {
                            await viewModel.createAccountWithEmail(email: normalizedEmail, password: password, requestedRole: requestedRole)
                            if viewModel.errorMessage == nil { dismiss() }
                        }
                    }
                    .disabled(!canSubmit || viewModel.requestedRole == nil)
                }
            }
            .navigationTitle("Email Sign In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !normalizedEmail.isEmpty && password.count >= 6 && !viewModel.isLoading
    }
}
