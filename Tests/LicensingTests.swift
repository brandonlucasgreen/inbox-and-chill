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

    @Test func onlyExpiryPausesSync() {
        #expect(LicenseState.trialing(daysLeft: 1).allowsSync)
        #expect(LicenseState.licensed.allowsSync)
        #expect(!LicenseState.expired.allowsSync)
    }

    @Test func datesRoundTripThroughKeychainEncoding() {
        let encoded = Licensing.encode(start)
        #expect(Licensing.decodeDate(encoded) == start)
        #expect(Licensing.decodeDate(nil) == nil)
        #expect(Licensing.decodeDate("not a date") == nil)
    }
}

// MARK: - Lemon Squeezy response parsing

/// Fixtures follow the shapes in the License API docs
/// (docs.lemonsqueezy.com/api/license-api). Doc-derived, not yet verified
/// against the live API — the live check happens once the store exists.
@Suite("Lemon Squeezy parsing")
struct LemonSqueezyParsingTests {
    @Test func activationSuccess() throws {
        let fixture = """
            {"activated": true, "error": null,
             "license_key": {"id": 1, "status": "active",
                             "key": "REDACTED",
                             "activation_limit": 3, "activation_usage": 1},
             "instance": {"id": "47596ad9-a811-4ebf-ac8a-03fc7b6d2a17",
                          "name": "Brandons MacBook Pro"},
             "meta": {"store_id": 12345, "product_id": 11}}
            """
        let result = try LemonSqueezy.activation(
            from: Data(fixture.utf8), expectedStoreID: nil)
        #expect(
            result
                == .activated(
                    .init(
                        instanceID: "47596ad9-a811-4ebf-ac8a-03fc7b6d2a17")))
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
            from: Data(fixture.utf8), expectedStoreID: 12345)
        guard case .refused(let reason) = pinned else {
            Issue.record("expected a refusal, got \(pinned)")
            return
        }
        #expect(reason.contains("different product"))
        // Unpinned (the pre-launch state), the same response activates.
        let unpinned = try LemonSqueezy.activation(
            from: Data(fixture.utf8), expectedStoreID: nil)
        #expect(unpinned == .activated(.init(instanceID: "abc")))
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

    @Test func unknownKeyFallsBackToTheAPIsError() throws {
        let fixture = """
            {"valid": false, "error": "license_key not found"}
            """
        #expect(
            try LemonSqueezy.validation(
                from: Data(fixture.utf8), expectedStoreID: nil)
                == .invalid(reason: "license_key not found"))
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
