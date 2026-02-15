import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    static func assertConfigured(context: String) {
        guard FirebaseApp.app() != nil else {
            let message = "⚠️ Firebase used before FirebaseApp.configure() at \(context)"
            assertionFailure(message)
            print(message)
            return
        }
    }
}
