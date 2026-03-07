import Foundation

enum CloudKitBootstrap {
    static func configureIfNeeded(caller: String = #function) {
        AppLog.info("CloudKit bootstrap complete (caller=\(caller))")
    }
}
