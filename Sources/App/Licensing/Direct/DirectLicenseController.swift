import Foundation

/// The **direct build's** `LicenseController`, and it has nothing to control:
/// the direct build has been free since 2026-11-16 (1.1.0), with a Ko-fi link
/// in About instead of a checkout. It used to be a Lemon Squeezy license-key
/// controller (`Licensing/LemonSqueezy/`, deleted once Lemon Squeezy
/// announced its shutdown); this stub keeps the same surface so `AppState`,
/// `LicenseNotice`, the welcome and the trial nudge compile unchanged against
/// either build, the way `UpdateController`'s store stub does.
///
/// Everything reads as licensed and nothing ever fires. `Licensing.isEnforced`
/// is false as well, so no shared view reads this at all — the stub is
/// belt and braces, not the mechanism.
///
/// Old installs still carry `license.*` items in their Keychain from 1.0.x.
/// Nothing reads them; they are left alone rather than deleted on launch.
///
/// The store build compiles `AppStore/StoreKitLicenseController.swift` under
/// the same name instead; `project.yml` gives each target exactly one.
@MainActor
@Observable
final class LicenseController {
    let state: LicenseState = .licensed
    let problem: String? = nil
    let isPurchasing = false
    let priceLabel: String? = nil
    let canStartTrial = false
    let trialEndsAt: Date? = nil

    /// Never fired: the state never changes.
    var onSyncPermissionChange: ((Bool) -> Void)?
    var onStateEvaluated: ((LicenseState) -> Void)?

    init() {}

    func startTrial() async {}
}
