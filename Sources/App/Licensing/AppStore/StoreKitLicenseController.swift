import Foundation
import OSLog
import StoreKit

/// The **App Store build's** `LicenseController`: owns the trial and the one
/// real purchase. Reads and writes the Keychain, talks to StoreKit 2, and
/// publishes one `LicenseState` for the UI plus a callback for `AppState` to
/// start or stop syncing on — the same surface the direct build's Lemon
/// Squeezy controller has, so `AppState`, `LicenseNotice`, the welcome and
/// the trial nudge compile unchanged against either.
///
/// The math is in `Licensing` (pure, tested); this class is the I/O around
/// it. Four rules shape it:
///
/// - **The trial starts when the user says so** — Start Free Trial on the
///   welcome window, the notice bar or Settings — never on launch (Brandon,
///   2026-09-10). The button buys guideline 3.1.1's $0 "14-day Trial"
///   product, whose `purchaseDate` becomes the server-signed anchor for the
///   clock. **If that purchase cannot happen — offline, the sheet
///   cancelled, a build that never met the store — the trial starts anyway
///   from a Keychain stamp.** A person who pressed Start must never be left
///   with a paused app because Apple's sheet did not cooperate.
/// - **The trial clock is the earliest credible date** of the stamp and the
///   $0 transaction (`Licensing.trialStart`). A trial started on another
///   Mac with the same Apple Account arrives through the entitlements and
///   shortens this one to match.
/// - **Offline never demotes.** A purchase is remembered in the Keychain the
///   moment StoreKit verifies it, and only an explicit revocation (a refund,
///   arriving through `Transaction.updates`) takes it away. An entitlement
///   list that comes back empty is not a verdict.
/// - **Nothing here prompts on its own.** `AppStore.sync()` shows a sign-in
///   sheet and the purchase sheet is Apple's, so both run only from a button
///   the user just pressed. Same discipline as the Mail Automation prompt
///   (CLAUDE.md rule 2).
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
    /// True while a purchase, trial start or restore sheet is up.
    private(set) var isPurchasing = false
    private(set) var unlockProduct: Product?
    private(set) var trialProduct: Product?
    /// Which clock the trial runs on (`Licensing.TrialAnchor`).
    private(set) var trialAnchor: Licensing.TrialAnchor = .local
    /// Fired when `state.allowsSync` flips: a trial starting or a purchase
    /// mid-run, or the trial running out under a live app (a menu bar app
    /// runs for weeks, so launch-time checks alone would miss it by days).
    var onSyncPermissionChange: ((Bool) -> Void)?
    /// Fired on every evaluation, changed or not — the trial nudges key off
    /// the day count, which changes without `allowsSync` flipping.
    var onStateEvaluated: ((LicenseState) -> Void)?

    /// What the purchase costs, localised by the App Store; nil until the
    /// product has loaded. Never hard-coded: the price is set in App Store
    /// Connect and may differ per storefront.
    var priceLabel: String? { unlockProduct?.displayPrice }

    /// When the running trial ends, for the welcome's second screen and
    /// Settings. Nil before the trial starts and after a purchase.
    var trialEndsAt: Date? {
        guard case .trialing = state,
            let start = Licensing.decodeDate(Keychain.get(Licensing.trialStartKey))
        else { return nil }
        return Licensing.trialEnd(start: start)
    }

    /// The direct build's controller has this too; `PurchaseSection` and the
    /// welcome use it to decide whether Start Free Trial is on offer.
    var canStartTrial: Bool { state == .notStarted }

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
        // No stamp at launch, on purpose: `.notStarted` until Start Free
        // Trial. The direct build stamps here; this one does not.
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
            await loadProducts()
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
    /// happens, not at the next relaunch. Also retries products that failed
    /// to load, so a launch with no network still shows a price later.
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                self.refreshState()
                if self.unlockProduct == nil || self.trialProduct == nil {
                    await self.loadProducts()
                }
            }
        }
    }

    // MARK: Trial

    /// Start Free Trial. Buys the $0 trial product when it can; stamps the
    /// clock locally regardless, because the press is the decision and the
    /// sheet is a formality Apple asks for. Idempotent: a second press while
    /// a trial runs does nothing.
    func startTrial() async {
        guard forcedState == nil, state == .notStarted else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        var anchorFromStore: Date?
        if let trialProduct {
            do {
                switch try await trialProduct.purchase() {
                case .success(let result):
                    switch result {
                    case .verified(let transaction):
                        await transaction.finish()
                        anchorFromStore = transaction.purchaseDate
                    case .unverified(_, let error):
                        Self.log.notice(
                            "trial transaction failed verification, starting locally: \(String(describing: error), privacy: .public)"
                        )
                    }
                case .pending:
                    // Ask to Buy on a free item still parks the transaction
                    // with the organiser. The trial starts now regardless;
                    // the transaction, if approved, only re-anchors it.
                    Self.log.notice("trial purchase pending approval; starting locally")
                case .userCancelled:
                    Self.log.notice("trial sheet cancelled; starting locally")
                @unknown default:
                    break
                }
            } catch {
                Self.log.notice(
                    "trial purchase failed, starting locally: \(String(describing: error), privacy: .public)"
                )
            }
        } else {
            Self.log.notice("trial product not loaded; starting locally")
        }
        // A local start goes through the same decision as a store one; the
        // anchor `record` reports is what the log line below says.
        record(trialStart: anchorFromStore ?? .now, fromStore: anchorFromStore != nil)
        Self.log.notice(
            "trial started, anchored to \(self.trialAnchor.rawValue, privacy: .public)"
        )
    }

    /// Writes the trial start the clock should run from — the earliest
    /// credible of what is stored and what the store says — and re-derives.
    private func record(trialStart candidate: Date, fromStore: Bool) {
        let stored = Licensing.decodeDate(Keychain.get(Licensing.trialStartKey))
        guard let decision = fromStore
            ? Licensing.trialStart(stored: stored, trialTransaction: candidate, now: .now)
            : Licensing.trialStart(stored: stored ?? candidate, trialTransaction: nil, now: .now)
        else { return }
        trialAnchor = decision.anchor
        if decision.start != stored {
            if let failure = Keychain.set(
                Licensing.encode(decision.start), for: Licensing.trialStartKey)
            {
                // The clock would restart at every launch — a free app, not a
                // paused one — but a Keychain that refuses writes is worth a
                // red line, because tokens will fail to save the same way.
                problem = failure
                Self.log.error("trial start not saved: \(failure, privacy: .public)")
                return
            }
        }
        refreshState()
    }

    // MARK: Products

    private func loadProducts() async {
        guard forcedState == nil else { return }
        do {
            let products = try await Product.products(
                for: [Licensing.appStoreProductID, Licensing.trialProductID])
            unlockProduct = products.first { $0.id == Licensing.appStoreProductID }
            trialProduct = products.first { $0.id == Licensing.trialProductID }
            if unlockProduct == nil {
                // The id is in the binary and in App Store Connect; if they
                // disagree this is the only symptom, so it names the id.
                productProblem =
                    "The App Store has no product \"\(Licensing.appStoreProductID)\" for this app yet, so there is nothing to buy. If you're a customer seeing this, please email \(SupportContact.email)."
                Self.log.error("store product not found: \(Licensing.appStoreProductID, privacy: .public)")
            } else {
                productProblem = nil
            }
            if trialProduct == nil {
                // Not a user-facing problem: the trial starts locally.
                Self.log.error("trial product not found: \(Licensing.trialProductID, privacy: .public)")
            }
        } catch {
            productProblem = Self.unreachable(error)
            Self.log.notice(
                "store products not loaded: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: Purchase

    func purchase() async {
        guard forcedState == nil else { return }
        guard let unlockProduct else {
            problem = productProblem ?? Self.storeUnavailable
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await unlockProduct.purchase() {
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
    /// this Mac, then re-reads the entitlements — the unlock *and* a trial
    /// started on another Mac. **Shows a sign-in sheet**, so only ever
    /// called from the Restore Purchase button.
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

    /// Reads what StoreKit knows on this device. Only ever *grants* or
    /// *shortens*: an empty answer leaves a stored unlock alone (offline
    /// never demotes) and is logged so Diagnostics can say why a purchase
    /// looked missing; a trial transaction moves the clock earlier, never
    /// later.
    func refreshEntitlements() async {
        guard forcedState == nil else { return }
        var sawUnlock = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
                transaction.productID == Licensing.appStoreProductID
            {
                sawUnlock = true
            }
            apply(result, from: "entitlements")
        }
        if !sawUnlock, Keychain.get(Self.unlockedKey) == "true" {
            Self.log.notice(
                "no entitlement on this device; keeping the stored purchase (offline never demotes)"
            )
        }
    }

    private func apply(_ result: VerificationResult<Transaction>, from source: String) {
        switch result {
        case .verified(let transaction):
            apply(transaction: transaction)
        case .unverified(let transaction, let error):
            Self.log.notice(
                "ignoring unverified transaction for \(transaction.productID, privacy: .public) from \(source, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// A verified transaction for one of our products. The unlock grants
    /// unless revoked (refunded), which is the one path that locks again;
    /// the $0 trial re-anchors the clock to its purchase date.
    private func apply(transaction: Transaction) {
        switch transaction.productID {
        case Licensing.appStoreProductID:
            if let revoked = transaction.revocationDate {
                Keychain.delete(Self.unlockedKey)
                Self.log.error(
                    "purchase revoked on \(revoked.formatted(.iso8601), privacy: .public); trial state applies again"
                )
            } else if Keychain.get(Self.unlockedKey) != "true" {
                if let failure = Keychain.set("true", for: Self.unlockedKey) {
                    // The purchase is real and StoreKit remembers it; only
                    // our memo failed. Say so.
                    problem = failure
                } else {
                    Self.log.notice("purchase verified and remembered")
                }
            }
            refreshState()
        case Licensing.trialProductID:
            guard transaction.revocationDate == nil else { return }
            record(trialStart: transaction.purchaseDate, fromStore: true)
        default:
            return
        }
    }

    // MARK: Copy

    private static let storeUnavailable =
        "The App Store hasn't answered yet, so the price isn't known. Check your connection and try again in a moment."

    private static func unreachable(_ error: Error) -> String {
        "Couldn't reach the App Store — check your connection and try again. (\(error.localizedDescription))"
    }
}
