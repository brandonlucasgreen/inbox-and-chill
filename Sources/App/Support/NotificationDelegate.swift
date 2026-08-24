import Foundation
import UserNotifications

/// Routes banner clicks back into the app and shows banners while frontmost.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let uid =
            response.notification.request.content.userInfo["uid"] as? String
        completionHandler()
        guard let uid else { return }
        let state = appState  // @MainActor class — Sendable reference
        Task { @MainActor in
            state?.handleNotificationTap(uid: uid)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
