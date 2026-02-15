import Foundation

enum DebugOptions {
    #if DEBUG
    static let forceSignOutOnLaunch = false
    #else
    static let forceSignOutOnLaunch = false
    #endif
}
