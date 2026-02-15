import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    static func configureIfNeeded(source: String) {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
            print("✅ Firebase configured from: \(source)")
        } else {
            print("ℹ️ Firebase already configured: \(source)")
        }

        print("✅ Firebase ready: \(FirebaseApp.app() != nil)")
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
