import SwiftUI

@main
struct StoreCheckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appContainer: AppContainer

    init() {
        CloudKitBootstrap.configureIfNeeded(caller: "StoreCheckApp.init")
        _appContainer = StateObject(wrappedValue: AppContainer())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appContainer)
        }
    }
}
