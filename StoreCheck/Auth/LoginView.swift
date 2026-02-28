import SwiftUI
import AuthenticationServices
import UIKit

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
                .foregroundStyle(DS.Colors.textPrimary)

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

                AppleSignInButton {
                    guard let requestedRole = viewModel.requestedRole else { return }
                    Task { await viewModel.signInWithApple(requestedRole: requestedRole) }
                }
                .frame(height: 50)
                .disabled(viewModel.isLoading || viewModel.requestedRole == nil)
            }
            .frame(maxWidth: 420)

            if let notice = viewModel.signInNoticeMessage {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.yellow.opacity(0.9), in: Capsule())
            }

            if viewModel.isLoading { ProgressView().tint(DS.Colors.primary) }
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



private struct AppleSignInButton: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        // Pick ONE style:
        // .black, .white, .whiteOutline
        let button = ASAuthorizationAppleIDButton(
            type: .signIn,
            style: .whiteOutline
        )
        button.cornerRadius = 10
        button.addTarget(context.coordinator,
                         action: #selector(Coordinator.didTap),
                         for: UIControl.Event.touchUpInside)
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {}

    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }

        @objc func didTap() { action() }
    }
}
