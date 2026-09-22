import Foundation

/// Where the app stands with the trial and the purchase, as one value the UI
/// can switch over. Derived, never stored — the stored facts are the trial
/// start date and whatever proves a purchase (a Lemon Squeezy key in the
/// direct build, an App Store entitlement in the store build), and
/// `Licensing.state` recomputes this from them whenever anything changes.
enum LicenseState: Equatable {
    /// The store build before the user presses Start Free Trial. The direct
    /// build never produces it: its trial starts on first launch.
    case notStarted
    case trialing(daysLeft: Int)
    case expired
    case licensed

    /// Whether connectors may run. The queue itself is never gated: an
    /// expired trial pauses *syncing*, loudly, and touches nothing else —
    /// this app exists to stop things being dropped, so the one thing expiry
    /// must never do is silently stop collecting while looking alive. A trial
    /// that has not been started is paused the same way, and says so.
    ///
    /// Always `true` while `Licensing.isEnforced` is off.
    var allowsSync: Bool {
        Licensing.allowsSync(self, enforced: Licensing.isEnforced)
    }
}

/// Trial math — the pure half of licensing, shared by both builds and kept
/// free of Keychain, StoreKit and URLSession so every branch is testable
/// (rule 6). The I/O lives in one `LicenseController` per build:
/// `LemonSqueezy/` for the direct build, `AppStore/` for the store build.
/// Same class name, same surface, and each target compiles exactly one.
enum Licensing {
    /// **The master switch for the whole trial/purchase mechanic.**
    ///
    /// **Store build: on.** The App Store build is the one being sold: a
    /// free download, `trialDays` of full use, then a one-time in-app
    /// purchase to keep syncing (guideline 3.1.1; `docs/app-store-release.md`).
    ///
    /// **Direct build: on since 2026-09-13** (Brandon: *"I am almost ready
    /// to release it publicly"*). It was off from 2026-08-23 while a handful
    /// of people ran the direct build for free; the first build carrying
    /// `true` starts **their** 14 days on its first launch, because the
    /// switched-off controller deliberately never wrote a trial start date
    /// (the clock lives in the Keychain and survives reinstalls, so a
    /// disabled build that stamped it would have had every alpha user
    /// instantly expired the day the flag flipped). Anyone who already
    /// activated a key reads Licensed and sees no countdown.
    ///
    /// **To turn the direct build off again:** make the `#else` branch
    /// `false` and flip `mechanicIsOn` in `Tests/LicensingTests.swift` with
    /// it. While off the direct build behaves exactly as it did before
    /// licensing existed: no countdown, no notice, no License section, no
    /// call to Lemon Squeezy, and no trial start date written.
    ///
    /// Three things to check on a real install that the unit tests cannot:
    /// an existing install gets a fresh 14 days (its Keychain has no start
    /// date yet), a licensed install still reads Licensed, and the expiry
    /// notice appears (`INCHILL_LICENSE_STATE=expired` on a Debug build).
    #if APP_STORE
        static let isEnforced = true
    #else
        static let isEnforced = true
    #endif

    static let trialDays = 14

    /// The store build's two products, both non-consumable. Both ids are
    /// declared in `InboxAndChill.storekit` (local testing) and must be
    /// created by hand in App Store Connect with exactly these ids — a
    /// mismatch loads no product and the button never enables.
    /// `scripts/verify-bundle.sh --app-store` checks both literals are in
    /// the store binary.
    ///
    /// - `unlock`: the one-time purchase that turns the trial into forever.
    /// - `trial`: **Price Tier 0, named "14-day Trial"** — the mechanism
    ///   guideline 3.1.1 prescribes for a free trial in a non-subscription
    ///   app. Start Free Trial buys it; its `purchaseDate` is the trial
    ///   clock's server-signed anchor, which survives reinstalls on any Mac
    ///   signed into the same Apple Account. Brandon's call (2026-09-10):
    ///   an explicit start, *"much more user-friendly and standard"*.
    static let appStoreProductID = "lol.bgreen.inboxandchill.unlock"
    static let trialProductID = "lol.bgreen.inboxandchill.trial"

    /// Whether syncing is allowed, given a state and whether the mechanic is
    /// switched on at all.
    ///
    /// Pure and takes `enforced` as an argument rather than reading the
    /// constant, so the tests can pin **both** modes — otherwise the shipped
    /// value of a compile-time flag would decide which half of the contract
    /// is covered, and flipping it later would silently drop the other half.
    nonisolated static func allowsSync(
        _ state: LicenseState, enforced: Bool
    ) -> Bool {
        guard enforced else { return true }
        return state != .expired && state != .notStarted
    }

    // Keychain account (service lol.bgreen.inboxandchill, like everything
    // else). The trial start date lives in the Keychain rather than
    // UserDefaults deliberately: Keychain items survive app deletion, so
    // delete-and-reinstall doesn't reset the clock. `scripts/reset-first-run.sh`
    // wipes the whole service, so a genuine fresh start still gets a fresh trial.
    // Each build's controller adds its own keys beside this one.
    static let trialStartKey = "license.trialStartedAt"

    /// The one derivation. What counts as a valid purchase is the caller's
    /// business — a stored key the last validation did not reject, or an
    /// App Store entitlement — and either way an offline check that could not
    /// complete never demotes. **No start date means no trial yet**: the
    /// direct build's controller stamps one before it ever derives, so only
    /// the store build reaches `.notStarted`.
    nonisolated static func state(
        trialStartedAt: Date?, hasValidLicense: Bool, now: Date
    ) -> LicenseState {
        if hasValidLicense { return .licensed }
        guard let trialStartedAt else { return .notStarted }
        let days = daysLeft(trialStartedAt: trialStartedAt, now: now)
        return days > 0 ? .trialing(daysLeft: days) : .expired
    }

    /// When a trial that started at `start` ends. What the welcome's second
    /// screen and Settings print.
    nonisolated static func trialEnd(start: Date) -> Date {
        min(start, .distantFuture).addingTimeInterval(TimeInterval(trialDays) * 86_400)
    }

    /// Whole days of trial remaining, counting a started day as a full one
    /// (install day shows "14 days left"). A missing or future start date
    /// reads as a fresh trial — the controller writes `now` on first launch,
    /// and a start date ahead of the clock is clock weirdness, not evidence
    /// the user owes time.
    nonisolated static func daysLeft(trialStartedAt: Date?, now: Date) -> Int {
        let start = min(trialStartedAt ?? now, now)
        let end = start.addingTimeInterval(TimeInterval(trialDays) * 86_400)
        let remaining = end.timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int((remaining / 86_400).rounded(.up))
    }

    // MARK: Trial anchor (store build)

    /// What the store build's trial clock is anchored to.
    enum TrialAnchor: String, Equatable {
        /// The `purchaseDate` of the $0 "14-day Trial" transaction, signed
        /// by the App Store. Survives deleting the container, the Keychain
        /// item and the app, and follows the Apple Account to another Mac.
        case appStore = "App Store"
        /// The Keychain stamp this Mac wrote when Start Free Trial was
        /// pressed — the fallback when the $0 purchase could not happen
        /// (offline, cancelled sheet, or a build that never met the store).
        case local = "this Mac"
    }

    struct TrialStart: Equatable {
        var start: Date
        var anchor: TrialAnchor
    }

    /// Picks the trial start from the two facts the store build can have:
    /// the Keychain stamp and the $0 trial transaction's purchase date. The
    /// **earliest credible evidence wins** — a trial can only get shorter
    /// from what the App Store knows, never longer — and a date ahead of the
    /// clock is clock weirdness, not owed time (same rule as `daysLeft`).
    /// Nil when neither exists: the trial has not been started.
    ///
    /// Unlike `AppTransaction.originalPurchaseDate`, a transaction's
    /// `purchaseDate` is real in the sandbox too, so there is no environment
    /// exclusion here.
    nonisolated static func trialStart(
        stored: Date?, trialTransaction: Date?, now: Date
    ) -> TrialStart? {
        let local = stored.map { min($0, now) }
        let store = trialTransaction.flatMap { $0 <= now ? $0 : nil }
        switch (local, store) {
        case (nil, nil): return nil
        case (let l?, nil): return TrialStart(start: l, anchor: .local)
        case (nil, let t?): return TrialStart(start: t, anchor: .appStore)
        case (let l?, let t?):
            return t < l
                ? TrialStart(start: t, anchor: .appStore)
                : TrialStart(start: l, anchor: .local)
        }
    }

    // MARK: Encoding

    /// Dates cross the Keychain as ISO8601 strings.
    nonisolated static func encode(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    nonisolated static func decodeDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    // MARK: Debug override

    /// DEBUG-only escape hatch for UI iteration, same pattern as
    /// `INCHILL_FAKE`: `INCHILL_LICENSE_STATE=licensed|expired|trialing`
    /// (or `trialing:3`) freezes the state and skips Keychain, network and
    /// StoreKit. Shared by both controllers; a Release build ignores it.
    nonisolated static func forcedState(from environment: [String: String])
        -> LicenseState?
    {
        #if DEBUG
            switch environment["INCHILL_LICENSE_STATE"] {
            case "licensed": return .licensed
            case "expired": return .expired
            case .some(let value) where value.hasPrefix("trialing"):
                let days = value.split(separator: ":").last.flatMap {
                    Int($0)
                }
                return .trialing(daysLeft: days ?? Licensing.trialDays)
            default: return nil
            }
        #else
            return nil
        #endif
    }
}
