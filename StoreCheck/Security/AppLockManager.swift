import Foundation
import LocalAuthentication

@MainActor
final class AppLockManager: ObservableObject {
    @Published var isLocked: Bool = false
    @Published var biometricsEnabled: Bool = false
    @Published var lastErrorMessage: String?

    private var unlockInProgress = false
    private var lastUnlockAttemptAt: Date?
    private var lastBackgroundAt: Date?
    private let unlockThrottle: TimeInterval = 2
    private let foregroundGracePeriod: TimeInterval = 1

    init() {
        loadPreference()
        if biometricsEnabled {
            isLocked = true
        }
    }

    func loadPreference() {
        biometricsEnabled = KeychainStore.getBiometricsEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        biometricsEnabled = enabled
        KeychainStore.setBiometricsEnabled(enabled)

        if !enabled {
            isLocked = false
            lastErrorMessage = nil
            unlockInProgress = false
            lastUnlockAttemptAt = nil
        }
    }

    func markDidEnterBackground(at date: Date = Date()) {
        lastBackgroundAt = date
    }

    func lockIfNeededOnForeground() {
        guard biometricsEnabled else {
            isLocked = false
            return
        }

        if let lastBackgroundAt,
           Date().timeIntervalSince(lastBackgroundAt) < foregroundGracePeriod,
           !isLocked {
            return
        }

        lockNow()
        unlockIfAllowed(isManualRetry: false)
    }

    func lockNow() {
        guard biometricsEnabled else { return }
        isLocked = true
    }

    func unlock() {
        unlockIfAllowed(isManualRetry: true)
    }

    func canEvaluateBiometricsOnly() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    private func unlockIfAllowed(isManualRetry: Bool) {
        guard biometricsEnabled, isLocked, !unlockInProgress else { return }

        let now = Date()
        if !isManualRetry,
           let lastUnlockAttemptAt,
           now.timeIntervalSince(lastUnlockAttemptAt) < unlockThrottle {
            return
        }

        unlockInProgress = true
        lastUnlockAttemptAt = now
        lastErrorMessage = nil

        Task { @MainActor in
            defer { unlockInProgress = false }

            let result = await authenticateWithFallback()
            switch result {
            case .success:
                isLocked = false
                lastErrorMessage = nil
            case .failure:
                isLocked = true
                lastErrorMessage = "Authentication was canceled or failed. Please try again."
            }
        }
    }

    private func authenticateWithFallback() async -> Result<Void, Error> {
        let biometricContext = LAContext()
        biometricContext.localizedCancelTitle = "Cancel"

        var biometricError: NSError?
        if biometricContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError) {
            let biometricResult = await evaluate(
                context: biometricContext,
                policy: .deviceOwnerAuthenticationWithBiometrics,
                reason: "Unlock StorePass"
            )

            switch biometricResult {
            case .success:
                return .success(())
            case .failure(let error):
                if let laError = error as? LAError, laError.code == .biometryLockout {
                    return await evaluatePasscodeFallback()
                }
                return .failure(error)
            }
        }

        return await evaluatePasscodeFallback()
    }

    private func evaluatePasscodeFallback() async -> Result<Void, Error> {
        let fallbackContext = LAContext()
        fallbackContext.localizedCancelTitle = "Cancel"

        var fallbackError: NSError?
        guard fallbackContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &fallbackError) else {
            return .failure(fallbackError ?? LAError(.authenticationFailed))
        }

        return await evaluate(
            context: fallbackContext,
            policy: .deviceOwnerAuthentication,
            reason: "Unlock StorePass"
        )
    }

    private func evaluate(context: LAContext, policy: LAPolicy, reason: String) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .success(()))
                } else {
                    continuation.resume(returning: .failure(error ?? LAError(.authenticationFailed)))
                }
            }
        }
    }
}
