import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            print("[Push] authorization granted=\(granted) error=\(String(describing: error))")
        }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, !token.isEmpty else { return }
        Task { await persistDeviceToken(token) }
    }

    private func persistDeviceToken(_ token: String) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()

        var appMode = "employee"
        do {
            let userSnap = try await db.collection("users").document(uid).getDocument()
            if (userSnap.data()?["role"] as? String)?.lowercased() == "manager" {
                appMode = "manager"
            }
        } catch {
            print("[Push] role lookup failed uid=\(uid) error=\(error.localizedDescription)")
        }

        do {
            try await db.collection("users").document(uid).collection("deviceTokens").document(token).setData([
                "token": token,
                "platform": "ios",
                "bundleId": Bundle.main.bundleIdentifier ?? "",
                "appMode": appMode,
                "updatedAt": FieldValue.serverTimestamp(),
            ], merge: true)
            print("[Push] token saved uid=\(uid) appMode=\(appMode)")
        } catch {
            print("[Push] token save failed uid=\(uid) error=\(error.localizedDescription)")
        }
    }
}
