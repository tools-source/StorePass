import GoogleSignIn
import SwiftUI

@main
struct StoreCheckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appContainer = AppContainer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appContainer)
                .preferredColorScheme(nil)
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
