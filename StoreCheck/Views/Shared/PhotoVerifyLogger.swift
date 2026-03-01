enum PhotoVerifyLogger {
    static func log(_ message: String) {
        #if DEBUG
        print("[PhotoVerify] \(message)")
        #endif
    }
}