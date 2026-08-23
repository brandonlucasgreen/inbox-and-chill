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
    }

    /// The mechanic is switched off for the alpha. Nothing may pause syncing
    /// while it is — not even an expired clock, which is the state an alpha
    /// user would land in if a start date ever got stamped by mistake.
    @Test func nothingPausesSync_whenNotEnforced() {
        for state: LicenseState in [
            .trialing(daysLeft: 1), .licensed, .expired,
        ] {
            #expect(Licensing.allowsSync(state, enforced: false))
        }
    }

    /// A guard on the shipped value, so turning the mechanic on is a
    /// deliberate act that trips a red test rather than something that can
    /// ride along in an unrelated change. Flip both together.
    @Test func mechanicIsCurrentlyOff() {
        #expect(Licensing.isEnforced == false)
        #expect(LicenseState.expired.allowsSync)
    }

    @Test func datesRoundTripThroughKeychainEncoding() {
        let encoded = Licensing.encode(start)
        #expect(Licensing.decodeDate(encoded) == start)
        #expect(Licensing.decodeDate(nil) == nil)
        #expect(Licensing.decodeDate("not a date") == nil)
    }
}

// MARK: - Lemon Squeezy response parsing

/// Fixtures **captured from the live API** on 2026-08-22, by activating,
/// validating and deactivating a real test-mode key against store 188119.
/// Keys and ids are redacted; the shapes are verbatim. This supersedes the
/// doc-derived fixtures these started as (rule 4: a config that has never
/// met the real service is unverified).
@Suite("Lemon Squeezy parsing")
struct LemonSqueezyParsingTests {
    @Test func activationSuccess() throws {
        let fixture = """
            {"activated": true, "error": null,
             "license_key": {"id": 1555197, "status": "active",
                             "key": "REDACTED",
                             "activation_limit": 2, "activation_usage": 1,
                             "created_at": "2026-08-23T02:00:43.000000Z",
                             "expires_at": null, "test_mode": false},
             "instance": {"id": "512d5452-7a35-4861-bd29-4c8a8784e4a9",
                          "name": "Brandons MacBook Pro",
                          "created_at": "2026-08-23T02:05:03.000000Z"},
             "meta": {"store_id": 188119, "order_id": 9283538,
                      "variant_name": "Default", "product_id": 1309536,
                      "product_name": "Inbox & Chill",
                      "customer_name": "Brandon Lucas Green"}}
            """
        let result = try LemonSqueezy.activation(
            from: Data(fixture.utf8), expectedStoreID: 188_119)
        #expect(
            result
                == .activated(
                    .init(
                        instanceID: "512d5452-7a35-4861-bd29-4c8a8784e4a9",
                        isTestMode: false)))
    }

    /// A test-mode key reports the **same** `store_id` as a live one, so the
    /// store pin cannot separate them — the app records the flag instead and
    /// says so in Settings. Verified against the live API.
    @Test func testModeKeyActivatesAndIsFlagged() throws {
        let fixture = """
            {"activated": true, "error": null,
             "license_key": {"id": 1555197, "status": "active",
                             "activation_limit": 2, "activation_usage": 1,
                             "test_mode": true},
             "instance": {"id": "512d5452", "name": "probe"},
             "meta": {"store_id": 188119}}
            """
        let result = try LemonSqueezy.activation(
            from: Data(fixture.utf8), expectedStoreID: 188_119)
        #expect(
            result == .activated(.init(instanceID: "512d5452", isTestMode: true)))
    }

    @Test func activationRefusalCarriesLemonSqueezysWording() throws {
        let fixture = """
            {"activated": false,
             "error": "This license key has reached the activation limit.",
             "license_key": {"status": "active"}}
            """
        let result = try LemonSqueezy.activation(
            from: Data(fixture.utf8), expectedStoreID: nil)
        #expect(
            result
                == .refused(
                    "This license key has reached the activation limit."))
    }

    /// The License API takes only the key, so any store's key would
    /// otherwise activate the app. The pin turns a foreign key into a
    /// refusal with a reason.
    @Test func activationFromAnotherStoreIsRefused() throws {
        let fixture = """
            {"activated": true, "error": null,
             "instance": {"id": "abc"}, "meta": {"store_id": 99999}}
            """
        let pinned = try LemonSqueezy.activation(
            from: Data(fixture.utf8), expectedStoreID: 188_119)
        guard case .refused(let reason) = pinned else {
            Issue.record("expected a refusal, got \(pinned)")
            return
        }
        #expect(reason.contains("different product"))
        // Unpinned, the same response activates — guards the pin itself
        // being what refuses, rather than something else in the response.
        let unpinned = try LemonSqueezy.activation(
            from: Data(fixture.utf8), expectedStoreID: nil)
        #expect(
            unpinned == .activated(.init(instanceID: "abc", isTestMode: false)))
    }

    /// The shipped pin is the real store id, so a key from it activates.
    @Test func shippedStorePinAcceptsItsOwnStore() throws {
        #expect(Licensing.expectedStoreID == 188_119)
        let fixture = """
            {"activated": true, "instance": {"id": "abc"},
             "meta": {"store_id": 188119}}
            """
        #expect(
            try LemonSqueezy.activation(from: Data(fixture.utf8))
                == .activated(.init(instanceID: "abc", isTestMode: false)))
    }

    @Test func validationValid() throws {
        let fixture = """
            {"valid": true, "error": null,
             "license_key": {"status": "active"},
             "instance": {"id": "abc"}, "meta": {"store_id": 12345}}
            """
        #expect(
            try LemonSqueezy.validation(
                from: Data(fixture.utf8), expectedStoreID: 12345) == .valid)
    }

    /// "disabled" is the refund/revocation status, and the message has to
    /// say so — the raw word explains nothing.
    @Test func disabledKeyExplainsItself() throws {
        let fixture = """
            {"valid": false, "error": null,
             "license_key": {"status": "disabled"}}
            """
        let result = try LemonSqueezy.validation(
            from: Data(fixture.utf8), expectedStoreID: nil)
        guard case .invalid(let reason) = result else {
            Issue.record("expected invalid, got \(result)")
            return
        }
        #expect(reason.contains("disabled"))
        #expect(reason.contains("refund"))
    }

    /// Verbatim from the live API for a mistyped key — and it arrives with
    /// **HTTP 404**, which is why the transport parses the body regardless
    /// of status code instead of throwing on non-2xx.
    @Test func unknownKeyFallsBackToTheAPIsError() throws {
        let fixture = """
            {"valid": false, "error": "license_key not found."}
            """
        #expect(
            try LemonSqueezy.validation(
                from: Data(fixture.utf8), expectedStoreID: nil)
                == .invalid(reason: "license_key not found."))
    }

    @Test func deactivation() throws {
        #expect(
            try LemonSqueezy.deactivation(
                from: Data(#"{"deactivated": true, "error": null}"#.utf8)))
        #expect(
            try !LemonSqueezy.deactivation(
                from: Data(#"{"deactivated": false}"#.utf8)))
    }

    /// Not-an-answer must throw, never return a verdict: callers treat a
    /// throw like a network failure, and the stored state stands. A parse
    /// error demoting a licensed user is the failure this shape prevents.
    @Test func garbageThrowsInsteadOfAnswering() {
        #expect(throws: LemonSqueezy.ParseError.self) {
            try LemonSqueezy.validation(
                from: Data("<html>502 Bad Gateway</html>".utf8),
                expectedStoreID: nil)
        }
        #expect(throws: LemonSqueezy.ParseError.self) {
            // Valid JSON that answers a different question is still not an
            // answer to this one.
            try LemonSqueezy.activation(
                from: Data(#"{"message": "maintenance"}"#.utf8),
                expectedStoreID: nil)
        }
    }

    @Test func formBodyPercentEncodesValues() {
        let body = LicenseController.formBody([
            "license_key": "abc-123",
            "instance_name": "Brandon's MacBook Pro",
        ])
        #expect(
            body
                == "instance_name=Brandon%27s%20MacBook%20Pro&license_key=abc-123"
        )
    }
}
