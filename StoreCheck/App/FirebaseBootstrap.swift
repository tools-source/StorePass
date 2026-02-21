import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    private static let lock = NSLock()

    static func configureIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        print("🔥 FirebaseApp.app() BEFORE configure =", FirebaseApp.app() as Any)

        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        print("🔥 Firebase configured. ProjectID =", FirebaseApp.app()?.options.projectID ?? "nil")
    }

    static func assertConfigured(context: String) {
        #if DEBUG
        guard FirebaseApp.app() != nil else {
            fatalError("Firebase accessed before FirebaseBootstrap.configureIfNeeded(). Context: \(context)")
        }
        #endif
    }
}
