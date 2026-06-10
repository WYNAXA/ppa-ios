import UIKit
import OneSignalFramework

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // OneSignal setup
        OneSignal.Debug.setLogLevel(.LL_VERBOSE)
        OneSignal.initialize("7becb264-45de-4744-8134-91eee6a6c826", withLaunchOptions: launchOptions)
        OneSignal.Notifications.requestPermission({ accepted in
            print("OneSignal push permission: \(accepted)")
        }, fallbackToSettings: true)

        UNUserNotificationCenter.current().delegate = self

        return true
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        print("push userInfo (foreground):", userInfo)
        sendPushToWebView(userInfo: userInfo)
        completionHandler([[.banner, .list, .sound]])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("push userInfo (tapped):", userInfo)
        sendPushClickToWebView(userInfo: userInfo)
        completionHandler()
    }
}
