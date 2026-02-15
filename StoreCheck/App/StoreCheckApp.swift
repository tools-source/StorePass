import FirebaseCore
import GoogleSignIn
import SwiftUI

@main
struct StoreCheckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appContainer: AppContainer

    init() {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        _appContainer = StateObject(wrappedValue: AppContainer.shared)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appContainer)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
