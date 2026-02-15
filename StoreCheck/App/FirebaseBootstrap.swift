import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    static func assertConfigured(context: String) {
        #if DEBUG
        guard FirebaseApp.app() != nil else {
            fatalError("Firebase accessed before AppDelegate completed FirebaseApp.configure(). Context: \(context)")
        }
        #endif
    }
}
