import GoogleSignIn
import SwiftUI

@main
struct StoreCheckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appContainer: AppContainer

    init() {
        FirebaseBootstrap.configureIfNeeded(caller: "StoreCheckApp.init")
        _appContainer = StateObject(wrappedValue: AppContainer())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appContainer)
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
