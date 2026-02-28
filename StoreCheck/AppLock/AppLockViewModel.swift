import Foundation
import SwiftUI

@MainActor
final class AppLockViewModel: ObservableObject {
    @Published var isLocked = false
    @Published var isAuthenticating = false
    @Published var lastAuthFailed = false

    @AppStorage("appLockEnabled") private var appLockEnabled = false

    private let authService: BiometricAuthService

    init(authService: BiometricAuthService = BiometricAuthService()) {
        self.authService = authService
    }

    func onAppBecameActive(isUserSignedIn: Bool) {
        guard isUserSignedIn, appLockEnabled else {
            isLocked = false
            lastAuthFailed = false
            return
        }

        isLocked = true

        Task {
            await unlock()
        }
    }

    func unlock() async {
        guard appLockEnabled else {
            isLocked = false
            lastAuthFailed = false
            return
        }

        guard !isAuthenticating else { return }

        isAuthenticating = true
        defer { isAuthenticating = false }

        let success = await authService.authenticate(reason: "Unlock StorePass")
        if success {
            isLocked = false
            lastAuthFailed = false
        } else {
            isLocked = true
            lastAuthFailed = true
        }
    }

    func unlockForDisabledAppLock() {
        isLocked = false
        lastAuthFailed = false
    }
}
