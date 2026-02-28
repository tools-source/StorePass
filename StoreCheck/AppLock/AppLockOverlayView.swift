import SwiftUI

struct AppLockOverlayView: View {
    let biometricType: BiometricType
    let isAuthenticating: Bool
    let lastAuthFailed: Bool
    let onTryAgain: () -> Void

    var body: some View {
        EmptyView()
            .onAppear {
                _ = biometricType
                _ = isAuthenticating
                _ = lastAuthFailed
                onTryAgain()
            }
    }
}
