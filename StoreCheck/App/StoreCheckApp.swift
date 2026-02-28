import GoogleSignIn
import SwiftUI

@main
struct StoreCheckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appContainer: AppContainer
    @StateObject private var appLock = AppLockManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wentBackgroundAt: Date?

    init() {
        FirebaseBootstrap.configureIfNeeded(caller: "StoreCheckApp.init")
        _appContainer = StateObject(wrappedValue: AppContainer())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appContainer)
                .environmentObject(appLock)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .inactive, .background:
                        let now = Date()
                        wentBackgroundAt = now
                        appLock.markDidEnterBackground(at: now)
                    case .active:
                        _ = wentBackgroundAt
                        appLock.lockIfNeededOnForeground()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
