import SwiftUI

struct AppLockOverlayView: View {
    let biometricType: BiometricType
    let isAuthenticating: Bool
    let lastAuthFailed: Bool
    let onTryAgain: () -> Void

    var body: some View {
        ZStack {
            DS.Colors.background.opacity(0.98)
                .ignoresSafeArea()

            VStack(spacing: DS.Spacing.m) {
                Image(systemName: iconName)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white)

                Text("App Locked")
                    .font(.title2.weight(.semibold))

                Text("Use \(biometricLabel) or your passcode to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if isAuthenticating {
                    ProgressView("Authenticating…")
                        .padding(.top, 8)
                } else {
                    Button("Try Again", action: onTryAgain)
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 4)
                }

                if lastAuthFailed {
                    Text("Authentication was canceled or failed. Please try again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(DS.Spacing.l)
            .frame(maxWidth: 360)
            .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, DS.Spacing.l)
        }
    }

    private var biometricLabel: String {
        switch biometricType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .none: return "biometrics"
        }
    }

    private var iconName: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .none: return "lock.fill"
        }
    }
}
