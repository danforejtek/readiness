import Observation
import OSLog
import UIKit
import UserNotifications

/// Cross-screen requests, e.g. "open the measurement" from a tapped reminder.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var measureRequested = false
    /// Next planned morning reminder, published by `ReminderService` after each re-plan.
    var nextReminder: Date?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Show the reminder even if the app happens to be open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Tapping the reminder opens the measurement screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier.hasPrefix(ReminderService.idPrefix) {
            Logger(subsystem: "com.danforejtek.readiness", category: "reminder").info("reminder tapped: opening measurement")
            Task { @MainActor in AppRouter.shared.measureRequested = true }
        }
        completionHandler()
    }
}
