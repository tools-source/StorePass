import SwiftUI

@main
struct StoreCheckApp: App {
    (AppDelegate.self) private var appDelegate
    @StateObject private var appContainer = AppContainer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appContainer)
                .preferredColorScheme(nil)
        }
    }
}
