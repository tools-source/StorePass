import AuthenticationServices
import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var viewModel: AuthViewModel
    @State private var showError = false

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Spacer()
            VStack(spacing: DS.Spacing.s) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(DS.Colors.primary)
                Text("StorePass")
                    .font(DS.Typography.largeTitle)
                Text("Secure check-ins for employees and managers")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            CardView {
                VStack(spacing: DS.Spacing.m) {
                    Picker("Mode", selection: $viewModel.requestedRole) {
                        Text("Employee").tag(Optional(UserRole.employee))
                        Text("Manager").tag(Optional(UserRole.manager))
                    }
                    .pickerStyle(.segmented)

                    Button("Continue with Google") {
                        guard let requestedRole = viewModel.requestedRole else { return }
                        Task { await viewModel.signInWithGoogle(requestedRole: requestedRole) }
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    AppleSignInButton {
                        guard let requestedRole = viewModel.requestedRole else { return }
                        Task { await viewModel.signInWithApple(requestedRole: requestedRole) }
                    }
                    .frame(height: 50)
                    .disabled(viewModel.isLoading || viewModel.requestedRole == nil)
                }
            }

            if let notice = viewModel.signInNoticeMessage {
                BannerView(text: notice, isError: true)
                    .padding(.horizontal, DS.Spacing.m)
            }
            Spacer()
        }
        .padding(DS.Spacing.l)
        .background(DS.Colors.background.ignoresSafeArea())
        .overlay {
            if viewModel.isLoading {
                LoadingOverlay(message: "Signing in…")
            }
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

private struct AppleSignInButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: .whiteOutline)
        button.cornerRadius = 10
        button.addTarget(context.coordinator, action: #selector(Coordinator.didTap), for: UIControl.Event.touchUpInside)
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {}

    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func didTap() { action() }
    }
}
