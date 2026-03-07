import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: .cloudKitDidReceiveRemoteChange, object: nil, userInfo: userInfo)
        completionHandler(.newData)
    }
}

extension Notification.Name {
    static let cloudKitDidReceiveRemoteChange = Notification.Name("cloudKitDidReceiveRemoteChange")
}
