import Foundation

enum DebugOptions {
    #if DEBUG
    static var isUITestingEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }
    static var forceSignOutOnLaunch: Bool {
        isUITestingEnabled
    }
    #else
    static let forceSignOutOnLaunch = false
    static let isUITestingEnabled = false
    #endif
}

enum AppLog {
    static func info(_ message: String) {
        #if DEBUG
        print("[StorePass][INFO] \(message)")
        #endif
    }

    static func warning(_ message: String) {
        #if DEBUG
        print("[StorePass][WARN] \(message)")
        #endif
    }

    static func error(_ message: String, error: Error? = nil) {
        #if DEBUG
        if let error {
            print("[StorePass][ERROR] \(message) :: \(sanitize(error.localizedDescription))")
        } else {
            print("[StorePass][ERROR] \(message)")
        }
        #endif
    }

    static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }

    static func redactIdentifier(_ value: String) -> String {
        let prefix = value.prefix(6)
        return "\(prefix)…"
    }
}
