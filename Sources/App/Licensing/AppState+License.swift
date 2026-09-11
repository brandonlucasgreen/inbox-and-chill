import Foundation
import OSLog
import UserNotifications

/// `AppState`'s side of licensing: how the trial gates syncing, and the two
/// system banners the trial sends on its way out.
///
/// Compiled into **both** targets against whichever `LicenseController` the
/// target has — `LemonSqueezy/` in the direct build, `AppStore/` in the
/// store build (`docs/app-store-release.md`). Both expose the same `state`,
/// `priceLabel` and callbacks, which is all this file reads. `AppState`
/// keeps only the stored `license` property, which an extension cannot hold.
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

    /// Whether connectors may run right now. An ended trial pauses syncing
    /// — loudly, in the panel and Settings (`LicenseNotice`) — and gates
    /// nothing else: the queue, the archive and every triage action keep
    /// working on what's already here.
    var syncAllowedByLicense: Bool { license.state.allowsSync }

    /// The controller evaluated its state before `configureLicensing` set
    /// the callback, so the launch-time evaluation is replayed by hand.
    func replayLicenseEvaluation() async {
        await nudgeIfTrialEnding(license.state)
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
        content.body = TrialNudge.body(price: license.priceLabel)
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

/// The two banners the trial sends on its way out, once each.
///
/// `LicenseNotice` already shows a countdown bar in the panel for the last
/// three days, but only to someone who opens the panel. A banner reaches the
/// person who has not — which, near the end of a trial, is the person about
/// to be surprised by paused syncing. Pure, so the thresholds and the
/// once-only rule are tested without a notification center.
enum TrialNudge {
    /// Days-left values at which a banner is due.
    static let thresholds = [3, 1]
    static let sentKey = "license.nudgesSent"

    /// The banner to send now, or nil. The *smallest* matching threshold, so
    /// a trial first noticed at one day left sends one banner, not two.
    nonisolated static func due(daysLeft: Int, sent: Set<Int>) -> Int? {
        thresholds.filter { daysLeft <= $0 && !sent.contains($0) }.min()
    }

    /// Everything at or above today's mark counts as sent, so the three-day
    /// banner is not delivered the day after the one-day banner.
    nonisolated static func markSent(daysLeft: Int, sent: Set<Int>) -> Set<Int> {
        sent.union(thresholds.filter { daysLeft <= $0 })
    }

    nonisolated static func title(daysLeft: Int) -> String {
        switch daysLeft {
        case ...0: return "Inbox & Chill trial ends today"
        case 1: return "Inbox & Chill trial — 1 day left"
        default: return "Inbox & Chill trial — \(daysLeft) days left"
        }
    }

    /// The price comes from the controller (StoreKit's localised
    /// `displayPrice` in the store build, the one constant in the direct
    /// build) and may not have loaded yet, so the sentence works without it.
    nonisolated static func body(price: String?) -> String {
        let cost = price.map { "buy the app (\($0))" } ?? "buy the app"
        #if !APP_STORE
            return
                "After that, syncing pauses until you \(cost) or enter a key. Your queue and settings stay put."
        #else
            return
                "After that, syncing pauses until you \(cost). Your queue and settings stay put."
        #endif
    }
}
