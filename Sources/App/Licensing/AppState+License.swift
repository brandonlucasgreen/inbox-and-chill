import Foundation
import OSLog
import UserNotifications

/// `AppState`'s side of licensing: how the trial gates syncing, and the two
/// system banners the trial sends on its way out.
///
/// Lives in `Licensing/` rather than in `AppState.swift` so the whole folder
/// can be left out of the App Store build, where a license key is a rejection
/// (guideline 2.4.5(vi); see `docs/app-store-plan.md`). `AppState` keeps only
/// the stored `license` property, which an extension cannot hold, and calls
/// `configureLicensing()` from `init`.
extension AppState {
    /// Wires the controller's callbacks. Called once from `AppState.init`,
    /// after `engine` exists.
    func configureLicensing() {
        // Trial expiry and activation both land mid-run — a menu bar app
        // lives for weeks, so launch-time gating alone would keep syncing
        // for days past the end of a trial.
        license.onSyncPermissionChange = { [weak self] allowed in
            guard let self else { return }
            Task { @MainActor in
                if allowed {
                    await self.bootstrapConnectors()
                    await self.engine.refreshNow()
                } else {
                    await self.engine.unregisterAll()
                }
            }
        }
        // The trial's last days are said out loud even to someone who has not
        // opened the panel; the in-panel bar (`LicenseNotice`) covers the rest.
        license.onStateEvaluated = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in await self.nudgeIfTrialEnding(state) }
        }
    }

    // MARK: Trial nudges

    /// A system banner at three days and at one day left, once each.
    ///
    /// `prompting: false` on purpose: a timer must not spend the banner
    /// permission prompt (the same rule Mail's Automation prompt follows), so
    /// with banners never granted this stays silent and `LicenseNotice` in
    /// the panel carries the countdown alone.
    func nudgeIfTrialEnding(_ state: LicenseState) async {
        guard Licensing.isEnforced, case .trialing(let daysLeft) = state else { return }
        let defaults = UserDefaults.standard
        let sent = Set(defaults.array(forKey: TrialNudge.sentKey) as? [Int] ?? [])
        guard let threshold = TrialNudge.due(daysLeft: daysLeft, sent: sent) else { return }
        defaults.set(
            Array(TrialNudge.markSent(daysLeft: daysLeft, sent: sent)).sorted(),
            forKey: TrialNudge.sentKey)
        guard await resolveBannerAuthorization(prompting: false) else { return }
        let content = UNMutableNotificationContent()
        content.title = TrialNudge.title(daysLeft: daysLeft)
        content.body = TrialNudge.body
        content.userInfo = ["panel": true]
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "license.nudge.\(threshold)", content: content,
                    trigger: nil))
        } catch {
            Self.licenseLog.notice(
                "trial nudge not delivered: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let licenseLog = AppLog.logger(.license)
}
