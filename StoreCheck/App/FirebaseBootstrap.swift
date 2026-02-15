import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    private static let lock = NSLock()

    static func configureIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
    }

    static func assertConfigured(context: String) {
        #if DEBUG
        guard FirebaseApp.app() != nil else {
            fatalError("Firebase accessed before FirebaseBootstrap.configureIfNeeded(). Context: \(context)")
        }
        #endif
    }
}
