import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @State private var showError = false
    @State private var email = ""

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
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button("Send Sign-In Link") {
                    Task { await viewModel.sendEmailSignInLink(to: normalizedEmail) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.isLoading || viewModel.requestedRole == nil || normalizedEmail.isEmpty)

                Button("Continue with Google") {
                    guard let requestedRole = viewModel.requestedRole else { return }
                    Task { await viewModel.signInWithGoogle(requestedRole: requestedRole) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(viewModel.isLoading || viewModel.requestedRole == nil)
            }
            .frame(maxWidth: 420)

            if viewModel.shouldPromptForEmailLinkCompletion {
                VStack(spacing: 10) {
                    Text("Finish Email Link Sign-In")
                        .font(.headline)
                        .foregroundStyle(.white)

                    TextField("Email", text: $viewModel.pendingEmailForCompletion)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button("Complete Sign-In") {
                        Task {
                            await viewModel.completePendingEmailLinkSignIn(email: viewModel.pendingEmailForCompletion)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(viewModel.isLoading || viewModel.pendingEmailForCompletion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: 420)
            }

            if let status = viewModel.emailLinkStatusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.white)
            }

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

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
