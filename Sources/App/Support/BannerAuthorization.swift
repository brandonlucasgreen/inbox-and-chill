import Foundation
import UserNotifications

/// Why banners are or aren't reaching the user, in the words Settings shows.
///
/// Deliberately free of `UNUserNotificationCenter`: the wording is the part
/// that has to be right, and a test process can't stand up the notification
/// system to exercise it. `UNAuthorizationStatus` is a plain enum, so the
/// mapping stays testable while the I/O it describes lives in `AppState`.
enum BannerAuthorization {
    enum Outcome: Equatable {
        /// macOS will deliver banners.
        case granted
        /// Nothing has asked macOS yet, so no banner can arrive. Not an
        /// error — but not silence either: the user gets a button to ask.
        case notRequested
        /// Asked and refused, with the reason to show.
        case blocked(String)

        /// The red-text message, or `nil` when there's nothing wrong to say.
        var message: String? {
            if case .blocked(let message) = self { return message }
            return nil
        }
    }

    /// The verdict for an already-settled status, or `nil` for
    /// `.notDetermined` — the one case where asking macOS is still on the
    /// table, and only the caller knows whether this is the moment for it.
    static func settledOutcome(status: UNAuthorizationStatus) -> Outcome? {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .blocked(deniedMessage)
        case .notDetermined:
            return nil
        @unknown default:
            // An unrecognised status is not a licence to assume delivery.
            return .blocked(
                "macOS reported a notification permission state Inbox & Chill doesn't recognise, so banners may not be delivered."
            )
        }
    }

    /// The verdict once `requestAuthorization` has answered.
    static func requestOutcome(granted: Bool, error: String?) -> Outcome {
        if let error, !error.isEmpty {
            return .blocked(
                "macOS refused the notification permission request, so no banners can be shown: \(error)"
            )
        }
        return granted ? .granted : .blocked(declinedMessage)
    }

    /// A banner macOS had permission for but still wouldn't take.
    static func postFailure(_ error: String) -> Outcome {
        .blocked("macOS rejected a banner: \(error)")
    }

    static let deniedMessage =
        "Notifications from Inbox & Chill are turned off in macOS, so no banners can be shown. Turn “Allow notifications” back on in System Settings › Notifications › Inbox & Chill."

    static let declinedMessage =
        "Notification permission was declined, so no banners can be shown. You can turn it on in System Settings › Notifications › Inbox & Chill."

    /// Deep link to System Settings › Notifications.
    static let systemSettingsURL = URL(
        string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!
}
