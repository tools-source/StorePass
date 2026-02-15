import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    static func configureIfNeeded(source: String) {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        print("✅ Firebase configured: \(FirebaseApp.app() != nil) [\(source)]")
    }

    static func assertConfigured(context: String) {
        guard FirebaseApp.app() != nil else {
            let message = "⚠️ Firebase used before FirebaseApp.configure() at \(context)"
            assertionFailure(message)
            print(message)
            return
        }
    }
}
