import Foundation

@MainActor
final class AppLockManager: ObservableObject {
    @Published var isLocked: Bool = false
    @Published var biometricsEnabled: Bool = false
    @Published var lastErrorMessage: String?

    init() {}

    func loadPreference() {
        biometricsEnabled = false
        isLocked = false
        lastErrorMessage = nil
    }

    func setEnabled(_ enabled: Bool) {
        biometricsEnabled = false
        isLocked = false
        lastErrorMessage = nil
        if enabled {
            print("[AppLock] App Lock has been removed; ignoring enable request.")
        }
    }

    func markDidEnterBackground(at date: Date = Date()) {
        _ = date
    }

    func lockIfNeededOnForeground() {
        isLocked = false
    }

    func lockNow() {
        isLocked = false
    }

    func unlock() {
        isLocked = false
    }

    func canEvaluateBiometricsOnly() -> Bool {
        false
    }
}
