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
        let userInfo = response.notification.request.content.userInfo
        let uid = userInfo["uid"] as? String
        // A banner about the app itself (the trial nudge) carries no item;
        // it opens the panel, where the notice bar has the Buy button.
        let opensPanel = userInfo["panel"] as? Bool == true
        completionHandler()
        let state = appState  // @MainActor class — Sendable reference
        if let uid {
            Task { @MainActor in state?.handleNotificationTap(uid: uid) }
        } else if opensPanel {
            Task { @MainActor in PanelToggler.toggle() }
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
