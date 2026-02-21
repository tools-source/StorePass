import FirebaseCore
import Foundation

enum FirebaseBootstrap {
    private static let lock = NSLock()

    static func configureIfNeeded(
        caller: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) {
        lock.lock()
        defer { lock.unlock() }

        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
            print("✅ Firebase configured:", FirebaseApp.app()?.options.projectID ?? "nil")
        }

        #if DEBUG
        if FirebaseApp.app() == nil {
            print("❌ Firebase initialization failed at \(caller) (\(file):\(line)).")
        }
        #endif
    }

    static func assertConfigured(
        context: String,
        file: String = #fileID,
        line: Int = #line
    ) {
        #if DEBUG
        guard FirebaseApp.app() != nil else {
            print("❌ [FirebaseBootstrap] Firebase accessed before initialization. Context: \(context). Location: \(file):\(line). Ensure FirebaseBootstrap.configureIfNeeded() is called synchronously in StoreCheckApp.init().")
            assertionFailure("Firebase accessed before initialization. Context: \(context) @ \(file):\(line)")
            return
        }
        #endif
    }
}
