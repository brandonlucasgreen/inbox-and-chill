import Foundation
import OSLog
import StoreKit

/// The **App Store build's** `LicenseController`: owns the trial clock and
/// the one in-app purchase. Reads and writes the Keychain, talks to StoreKit
/// 2, and publishes one `LicenseState` for the UI plus a callback for
/// `AppState` to start or stop syncing on — the same surface the direct
/// build's Lemon Squeezy controller has, so `AppState`, `LicenseNotice` and
/// the trial nudge compile unchanged against either.
///
/// The math is in `Licensing` (pure, tested); this class is the I/O around
/// it. Three rules shape it:
///
/// - **Offline never demotes.** A purchase is remembered in the Keychain the
///   moment StoreKit verifies it, and only an explicit revocation (a refund,
///   arriving through `Transaction.updates`) takes it away. An entitlement
///   list that comes back empty — signed out of the App Store, no network,
///   a build that never met the store — is not a verdict.
/// - **The trial clock is the earliest credible date.** Every launch stamps
///   the Keychain if nothing is there; then `AppTransaction.shared` is asked
///   for the App Store's own first-download date, which survives deleting
///   the container, the Keychain item and the app. `Licensing.trialStart`
///   decides between them and ignores the sandbox's fixed 2013 date.
/// - **Nothing here prompts on its own.** `AppTransaction.shared` throws
///   rather than asking anyone to sign in; `AppTransaction.refresh()` and
///   `AppStore.sync()` do show a sign-in sheet, so they run only from a
///   button the user just pressed (Restore Purchase). Same discipline as the
///   Mail Automation prompt (CLAUDE.md rule 2).
@MainActor
@Observable
final class LicenseController {
    private(set) var state: LicenseState
    /// Red text for Settings and the notice bar — a purchase or restore that
    /// failed, in words.
    private(set) var problem: String?
    /// Why the price is missing: the App Store could not be asked. Separate
    /// from `problem` because it is a fact about the network, not about a
    /// purchase, and only Settings shows it.
    private(set) var productProblem: String?
    /// Ask to Buy: a purchase that is waiting on a family organiser. Not an
    /// error, so not red.
    private(set) var pendingMessage: String?
    private(set) var isPurchasing = false
    private(set) var product: Product?
    /// Which clock the trial runs on (`Licensing.TrialAnchor`).
    private(set) var trialAnchor: Licensing.TrialAnchor = .local
    /// Fired when `state.allowsSync` flips: a purchase mid-run, or the trial
    /// running out under a live app (a menu bar app runs for weeks, so
    /// launch-time checks alone would miss the transition by days).
    var onSyncPermissionChange: ((Bool) -> Void)?
    /// Fired on every evaluation, changed or not — the trial nudges key off
    /// the day count, which changes without `allowsSync` flipping.
    var onStateEvaluated: ((LicenseState) -> Void)?

    /// What a purchase costs, localised by the App Store; nil until the
    /// product has loaded. Never hard-coded: the price is set in App Store
    /// Connect and may differ per storefront.
    var priceLabel: String? { product?.displayPrice }

    private let forcedState: LicenseState?
    private var clockTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?

    private static let log = AppLog.logger(.license)

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        forcedState = Licensing.forcedState(from: environment)
        if let forcedState {
            state = forcedState
            return
        }
        // First launch starts the clock. `Licensing.isEnforced` is `true` in
        // this build, so unlike the direct build there is no "do not stamp"
        // case: a store download is a trial from its first second.
        if Keychain.get(Licensing.trialStartKey) == nil {
            if let failure = Keychain.set(
                Licensing.encode(.now), for: Licensing.trialStartKey)
            {
                // The clock then restarts every launch — a free app, not a
                // paused one, so rule 5's loud failure is a log line rather
                // than a red bar. It would be the Keychain itself broken.
                Self.log.error(
                    "trial start not saved: \(failure, privacy: .public)")
            } else {
                Self.log.notice("trial started on this Mac")
            }
        }
        state = Self.derive()
        Self.log.notice(
            "license state resolved: \(String(describing: self.state), privacy: .public)"
        )
        startClock()
        // Refunds, Family Sharing changes and purchases completed elsewhere
        // arrive here, for as long as the app runs.
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                self.apply(result, from: "update")
            }
        }
        Task {
            await anchorTrialToAppStore()
            await loadProduct()
            await refreshEntitlements()
        }
    }

    // MARK: State

    /// The Keychain's memory of a verified purchase. Written by `apply`,
    /// cleared only by a revocation.
    static let unlockedKey = "license.appStoreUnlocked"

    private static func derive(now: Date = .now) -> LicenseState {
        let trialStart = Licensing.decodeDate(
            Keychain.get(Licensing.trialStartKey))
        let unlocked = Keychain.get(unlockedKey) == "true"
        return Licensing.state(
            trialStartedAt: trialStart, hasValidLicense: unlocked, now: now)
    }

    /// Recomputes from the Keychain and fires the sync callback on a flip.
    private func refreshState() {
        guard forcedState == nil else { return }
        let previous = state
        state = Self.derive()
        onStateEvaluated?(state)
        guard state != previous else { return }
        Self.log.notice(
            "license state resolved: \(String(describing: self.state), privacy: .public)"
        )
        if state.allowsSync != previous.allowsSync {
            onSyncPermissionChange?(state.allowsSync)
        }
    }

    /// Hourly recompute so the day the trial ends is noticed the day it
    /// happens, not at the next relaunch. Also retries a product that failed
    /// to load, so a launch with no network still shows a price later.
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                self.refreshState()
                if self.product == nil { await self.loadProduct() }
            }
        }
    }

    // MARK: Trial anchor

    /// Asks the App Store when this Apple Account first downloaded the app
    /// and moves the trial start *earlier* if that date is credible. Never
    /// later. `AppTransaction.shared` throws instead of prompting when the
    /// app has no App Store receipt — Xcode without a StoreKit
    /// configuration, or `dist/app-store/` — and the local stamp stands.
    private func anchorTrialToAppStore() async {
        guard forcedState == nil else { return }
        do {
            switch try await AppTransaction.shared {
            case .verified(let transaction):
                let stored = Licensing.decodeDate(
                    Keychain.get(Licensing.trialStartKey))
                let decision = Licensing.trialStart(
                    stored: stored,
                    appStore: transaction.originalPurchaseDate,
                    appStoreIsProduction: transaction.environment == .production,
                    now: .now)
                trialAnchor = decision.anchor
                if decision.start != stored {
                    _ = Keychain.set(
                        Licensing.encode(decision.start),
                        for: Licensing.trialStartKey)
                    refreshState()
                }
                Self.log.notice(
                    "trial anchored to \(decision.anchor.rawValue, privacy: .public) (app transaction environment: \(transaction.environment.rawValue, privacy: .public))"
                )
            case .unverified(_, let error):
                Self.log.notice(
                    "app transaction failed verification, trial stays on this Mac's stamp: \(String(describing: error), privacy: .public)"
                )
            }
        } catch {
            Self.log.notice(
                "app transaction unavailable, trial stays on this Mac's stamp: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: Product

    private func loadProduct() async {
        guard forcedState == nil else { return }
        do {
            let products = try await Product.products(
                for: [Licensing.appStoreProductID])
            if let first = products.first {
                product = first
                productProblem = nil
            } else {
                // The id is in the binary and in App Store Connect; if they
                // disagree this is the only symptom, so it names the id.
                productProblem =
                    "The App Store has no product \"\(Licensing.appStoreProductID)\" for this app yet, so there is nothing to buy. If you're a customer seeing this, please email \(SupportContact.email)."
                Self.log.error("store product not found: \(Licensing.appStoreProductID, privacy: .public)")
            }
        } catch {
            productProblem = Self.unreachable(error)
            Self.log.notice(
                "store product not loaded: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: Purchase

    func purchase() async {
        guard forcedState == nil else { return }
        guard let product else {
            problem = productProblem ?? Self.storeUnavailable
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                switch result {
                case .verified(let transaction):
                    await transaction.finish()
                    apply(transaction: transaction)
                    problem = nil
                    pendingMessage = nil
                case .unverified(_, let error):
                    // Paid, by the look of it, but the signature does not
                    // check out — do not unlock on it, do say what happened.
                    problem =
                        "The App Store returned a purchase this Mac couldn't verify (\(error.localizedDescription)). Try Restore Purchase in a minute; if that doesn't fix it, email \(SupportContact.email) — you won't be charged twice."
                }
            case .pending:
                pendingMessage =
                    "Your purchase is waiting for approval (Ask to Buy). Syncing continues the moment it's approved — nothing else to do here."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            problem = Self.unreachable(error)
        }
    }

    /// Restore: asks the App Store to sync this Apple Account's purchases to
    /// this Mac, then re-reads the entitlements. **Shows a sign-in sheet**,
    /// so only ever called from the Restore Purchase button.
    func restore() async {
        guard forcedState == nil else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            problem = nil
            if state != .licensed {
                problem =
                    "The App Store found no Inbox & Chill purchase for the Apple Account signed in on this Mac. If you bought it with a different account, sign in to the App Store with that one and try again."
            }
        } catch {
            problem = Self.unreachable(error)
        }
    }

    // MARK: Entitlements

    /// Reads what StoreKit knows on this device. Only ever *grants*: an empty
    /// answer leaves a stored unlock alone (offline never demotes) and is
    /// logged so the Diagnostics pane can say why a purchase looked missing.
    func refreshEntitlements() async {
        guard forcedState == nil else { return }
        var sawOurs = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
                transaction.productID == Licensing.appStoreProductID
            {
                sawOurs = true
            }
            apply(result, from: "entitlements")
        }
        if !sawOurs, Keychain.get(Self.unlockedKey) == "true" {
            Self.log.notice(
                "no entitlement on this device; keeping the stored purchase (offline never demotes)"
            )
        }
    }

    private func apply(_ result: VerificationResult<Transaction>, from source: String) {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == Licensing.appStoreProductID else { return }
            apply(transaction: transaction)
        case .unverified(let transaction, let error):
            Self.log.notice(
                "ignoring unverified transaction for \(transaction.productID, privacy: .public) from \(source, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// A verified transaction for our product: unlock, unless it has been
    /// revoked (refunded), which is the one path that locks again.
    private func apply(transaction: Transaction) {
        if let revoked = transaction.revocationDate {
            Keychain.delete(Self.unlockedKey)
            Self.log.error(
                "purchase revoked on \(revoked.formatted(.iso8601), privacy: .public); trial state applies again"
            )
        } else if Keychain.get(Self.unlockedKey) != "true" {
            if let failure = Keychain.set("true", for: Self.unlockedKey) {
                // The purchase is real and StoreKit remembers it; only our
                // memo failed. Unlock in memory for this run and say so.
                problem = failure
            } else {
                Self.log.notice("purchase verified and remembered")
            }
        }
        refreshState()
    }

    // MARK: Copy

    private static let storeUnavailable =
        "The App Store hasn't answered yet, so the price isn't known. Check your connection and try again in a moment."

    private static func unreachable(_ error: Error) -> String {
        "Couldn't reach the App Store — check your connection and try again. (\(error.localizedDescription))"
    }
}
