import Foundation
import Testing

@testable import InboxAndChill

// MARK: - Trial math

@Suite("Trial math")
struct TrialMathTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func installDayShowsFullTrial() {
        #expect(Licensing.daysLeft(trialStartedAt: start, now: start) == 14)
        #expect(
            Licensing.daysLeft(
                trialStartedAt: start, now: start.addingTimeInterval(3600))
                == 14)
    }

    @Test func lastHoursCountAsOneDay() {
        let almostOver = start.addingTimeInterval(13.9 * 86_400)
        #expect(
            Licensing.daysLeft(trialStartedAt: start, now: almostOver) == 1)
    }

    @Test func expiryIsExactlyFourteenDays() {
        let end = start.addingTimeInterval(14 * 86_400)
        #expect(Licensing.daysLeft(trialStartedAt: start, now: end) == 0)
        #expect(
            Licensing.daysLeft(
                trialStartedAt: start, now: end.addingTimeInterval(-1)) == 1)
        #expect(
            Licensing.daysLeft(
                trialStartedAt: start,
                now: end.addingTimeInterval(400 * 86_400)) == 0)
    }

    /// A start date ahead of the clock is clock weirdness, not time owed.
    @Test func futureStartDateReadsAsFresh() {
        let future = start.addingTimeInterval(5 * 86_400)
        #expect(Licensing.daysLeft(trialStartedAt: future, now: start) == 14)
    }

    @Test func missingStartDateReadsAsFresh() {
        #expect(Licensing.daysLeft(trialStartedAt: nil, now: start) == 14)
    }

    /// …but as a *state*, no start date is no trial: the store build's
    /// `.notStarted`, which pauses syncing until Start Free Trial. The
    /// direct build stamps before deriving, so it never sees this.
    @Test func missingStartDateIsNotStarted() {
        #expect(
            Licensing.state(trialStartedAt: nil, hasValidLicense: false, now: start)
                == .notStarted)
        #expect(
            Licensing.state(trialStartedAt: nil, hasValidLicense: true, now: start)
                == .licensed)
    }

    @Test func trialEndIsFourteenDaysOut() {
        #expect(Licensing.trialEnd(start: start) == start.addingTimeInterval(14 * 86_400))
    }

    @Test func stateDerivation() {
        let over = start.addingTimeInterval(20 * 86_400)
        #expect(
            Licensing.state(
                trialStartedAt: start, hasValidLicense: false, now: start)
                == .trialing(daysLeft: 14))
        #expect(
            Licensing.state(
                trialStartedAt: start, hasValidLicense: false, now: over)
                == .expired)
        // A valid license wins regardless of the trial clock.
        #expect(
            Licensing.state(
                trialStartedAt: start, hasValidLicense: true, now: over)
                == .licensed)
    }

    /// Both halves of the gate, pinned independently of which way the
    /// shipped flag happens to point — otherwise flipping `isEnforced` later
    /// would silently drop coverage of whichever mode stopped being live.
    @Test func onlyExpiryPausesSync_whenEnforced() {
        #expect(Licensing.allowsSync(.trialing(daysLeft: 1), enforced: true))
        #expect(Licensing.allowsSync(.licensed, enforced: true))
        #expect(!Licensing.allowsSync(.expired, enforced: true))
        // A trial nobody has started is paused too — the store build's
        // welcome, notice bar and Settings all say so and offer the button.
        #expect(!Licensing.allowsSync(.notStarted, enforced: true))
    }

    /// The switched-off mode, kept pinned even though both builds now ship
    /// enforced: nothing may pause syncing while the mechanic is off — not
    /// even an expired clock.
    @Test func nothingPausesSync_whenNotEnforced() {
        for state: LicenseState in [
            .trialing(daysLeft: 1), .licensed, .expired, .notStarted,
        ] {
            #expect(Licensing.allowsSync(state, enforced: false))
        }
    }

    /// A guard on the shipped value, so changing the mechanic's switch is a
    /// deliberate act that trips a red test rather than something that can
    /// ride along in an unrelated change. Off in both builds since
    /// 2026-11-16: the app is free (Ko-fi in the direct build, an optional
    /// purchase in the store build).
    @Test func mechanicIsOff() {
        #expect(Licensing.isEnforced == false)
        // The point of the switch: an install whose 1.0.x trial already ran
        // out must sync again once it updates.
        #expect(LicenseState.expired.allowsSync)
        #expect(LicenseState.notStarted.allowsSync)
    }

    @Test func datesRoundTripThroughKeychainEncoding() {
        let encoded = Licensing.encode(start)
        #expect(Licensing.decodeDate(encoded) == start)
        #expect(Licensing.decodeDate(nil) == nil)
        #expect(Licensing.decodeDate("not a date") == nil)
    }
}

// MARK: - Trial anchor (App Store build)

/// `Licensing.trialStart` chooses the clock the store build's trial runs
/// on. Pinned here because the StoreKit controller that calls it is compiled
/// only into the store target, which the tests never run against (rule 6).
@Suite("Trial anchor")
struct TrialAnchorTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var day: TimeInterval { 86_400 }

    /// Nothing stored, nothing from the store: no trial yet. This is the
    /// store build's launch state, and why launch stamps nothing.
    @Test func nothingKnownIsNotStarted() {
        #expect(Licensing.trialStart(stored: nil, trialTransaction: nil, now: now) == nil)
    }

    /// Start Free Trial with the store unreachable: the press is the start.
    @Test func localStampAloneStarts() {
        let decision = Licensing.trialStart(stored: now, trialTransaction: nil, now: now)
        #expect(decision == .init(start: now, anchor: .local))
    }

    /// The $0 trial transaction arriving on a Mac with no stamp — a
    /// reinstall, or a second Mac on the same Apple Account — starts the
    /// clock where the App Store says it started.
    @Test func storeTransactionAloneStarts() {
        let decision = Licensing.trialStart(
            stored: nil, trialTransaction: now - 5 * day, now: now)
        #expect(decision == .init(start: now - 5 * day, anchor: .appStore))
    }

    /// Both known: the earliest credible date wins, either way round.
    @Test func earliestWins() {
        #expect(
            Licensing.trialStart(stored: now - 2 * day, trialTransaction: now - 10 * day, now: now)
                == .init(start: now - 10 * day, anchor: .appStore))
        #expect(
            Licensing.trialStart(stored: now - 10 * day, trialTransaction: now - 2 * day, now: now)
                == .init(start: now - 10 * day, anchor: .local))
    }

    /// A date ahead of the clock is clock weirdness, not owed time — a
    /// future transaction is ignored, a future stamp is clamped to now.
    @Test func futureDatesAreNotTrusted() {
        #expect(
            Licensing.trialStart(stored: now - day, trialTransaction: now + day, now: now)
                == .init(start: now - day, anchor: .local))
        #expect(
            Licensing.trialStart(stored: now + day, trialTransaction: nil, now: now)
                == .init(start: now, anchor: .local))
    }

    /// The store build's product ids are fixed strings that must match App
    /// Store Connect and `InboxAndChill.storekit` by hand; pinning them here
    /// makes a rename a deliberate act.
    @Test func productIDsAreStable() {
        #expect(Licensing.appStoreProductID == "lol.bgreen.inboxandchill.unlock")
        #expect(Licensing.trialProductID == "lol.bgreen.inboxandchill.trial")
    }
}

/// The DEBUG override both controllers read. Tests build Debug, so the
/// parser is live here.
@Suite("Forced license state")
struct ForcedLicenseStateTests {
    @Test func parsesEachState() {
        #expect(Licensing.forcedState(from: ["INCHILL_LICENSE_STATE": "licensed"]) == .licensed)
        #expect(Licensing.forcedState(from: ["INCHILL_LICENSE_STATE": "expired"]) == .expired)
        #expect(
            Licensing.forcedState(from: ["INCHILL_LICENSE_STATE": "trialing"])
                == .trialing(daysLeft: Licensing.trialDays))
        #expect(
            Licensing.forcedState(from: ["INCHILL_LICENSE_STATE": "trialing:3"])
                == .trialing(daysLeft: 3))
    }

    @Test func anythingElseIsNoOverride() {
        #expect(Licensing.forcedState(from: [:]) == nil)
        #expect(Licensing.forcedState(from: ["INCHILL_LICENSE_STATE": "free"]) == nil)
    }
}

/// Guideline 3.1.1: duration, what stops, and the cost, before the trial
/// starts. The welcome window carries the sentence; this pins its parts.
@Suite("Trial disclosure")
struct TrialDisclosureTests {
    @Test func namesDurationWhatStopsAndPrice() {
        let text = FirstRun.trialDisclosure(price: "$14.99")
        #expect(text.contains("\(Licensing.trialDays) days"))
        #expect(text.contains("syncing pauses"))
        #expect(text.contains("$14.99"))
        #expect(text.contains("one-time"))
    }

    @Test func standsWithoutAPrice() {
        let text = FirstRun.trialDisclosure(price: nil)
        #expect(text.contains("one-time purchase"))
        #expect(!text.contains("nil"))
    }

    /// Screen two of the welcome: names the end day when it has one, and
    /// still reads as a sentence for the frame before the Keychain answers.
    @Test func startedMessageNamesTheEndDay() {
        let ends = Date(timeIntervalSince1970: 1_800_000_000)
        let text = FirstRun.trialStartedMessage(endsAt: ends)
        #expect(text.hasPrefix("Everything is on until "))
        #expect(text.hasSuffix("Now connect a source."))
        #expect(FirstRun.trialStartedMessage(endsAt: nil).contains("\(Licensing.trialDays) days"))
    }
}
