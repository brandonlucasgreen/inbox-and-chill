import Foundation

/// Where the app stands with the trial and the license, as one value the UI
/// can switch over. Derived, never stored — the stored facts are the trial
/// start date and the license key in the Keychain, and `Licensing.state`
/// recomputes this from them whenever anything changes.
enum LicenseState: Equatable {
    case trialing(daysLeft: Int)
    case expired
    case licensed

    /// Whether connectors may run. The queue itself is never gated: an
    /// expired trial pauses *syncing*, loudly, and touches nothing else —
    /// this app exists to stop things being dropped, so the one thing expiry
    /// must never do is silently stop collecting while looking alive.
    ///
    /// Always `true` while `Licensing.isEnforced` is off.
    var allowsSync: Bool {
        Licensing.allowsSync(self, enforced: Licensing.isEnforced)
    }
}

/// Trial math and Lemon Squeezy response parsing — the pure half of
/// licensing, kept free of Keychain and URLSession so every branch is
/// testable (rule 6). The I/O lives in `LicenseController`.
enum Licensing {
    /// **The master switch for the whole trial/licence mechanic. Off.**
    ///
    /// Turned off before the first alpha build carrying it (2026-08-23),
    /// deliberately and temporarily: a handful of people are already running
    /// Inbox & Chill, the product is not being sold yet, and shipping them a
    /// build that starts a countdown and then pauses their syncing would
    /// break a working app for no reason.
    ///
    /// While this is `false` the app behaves **exactly as it did before
    /// licensing existed**: no countdown, no expiry, no notice in the panel
    /// or the main window, no License section in Settings, no network call to
    /// Lemon Squeezy — and, most importantly, **no trial start date is
    /// written**.
    ///
    /// That last part is the one that would have bitten. The clock lives in
    /// the Keychain and survives reinstalls by design, so if a disabled build
    /// still stamped it, every alpha user's 14 days would elapse silently
    /// while nothing enforced them — and the day this flips to `true` they
    /// would all be *instantly expired*. Not stamping it means the trial
    /// starts when enforcement starts, which is the only fair reading.
    ///
    /// **To turn it back on:** flip this to `true`. That is the whole change;
    /// every gate and every piece of UI reads it. Then check three things,
    /// because none of them is covered by the unit tests: an existing install
    /// gets a fresh 14 days (its Keychain has no start date yet), a licensed
    /// install still reads Licensed, and the expiry notice actually appears
    /// (`INCHILL_LICENSE_STATE=expired` on a Debug build).
    static let isEnforced = false

    static let trialDays = 14
    static let price = "$15"

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
        return state != .expired
    }

    /// The Lemon Squeezy checkout page.
    static let purchaseURL: URL? = URL(
        string:
            "https://bgreenlol.lemonsqueezy.com/checkout/buy/274ad0c5-6ace-48fb-8dfb-a1f475c6f05d"
    )

    /// The Lemon Squeezy store this app's keys come from. The License API is
    /// public and takes only the key, so without this pin a valid key from
    /// *any* store on the platform would activate the app.
    ///
    /// Verified against the live API 2026-08-22: test-mode keys report the
    /// same `meta.store_id` as live ones, so this pin does not need a
    /// test-mode exception.
    static let expectedStoreID: Int? = 188_119

    // Keychain accounts (service lol.bgreen.inboxandchill, like everything
    // else). The trial start date lives in the Keychain rather than
    // UserDefaults deliberately: Keychain items survive app deletion, so
    // delete-and-reinstall doesn't reset the clock. `scripts/reset-first-run.sh`
    // wipes the whole service, so a genuine fresh start still gets a fresh trial.
    static let trialStartKey = "license.trialStartedAt"
    static let licenseKeyKey = "license.key"
    static let instanceIDKey = "license.instanceID"
    static let invalidReasonKey = "license.invalidReason"
    static let lastValidatedKey = "license.lastValidatedAt"
    static let testModeKey = "license.testMode"

    /// The one derivation. A stored license that the last validation
    /// explicitly rejected does not count — but a license we merely haven't
    /// been able to re-check does (offline never demotes; see
    /// `LicenseController.revalidateIfStale`).
    nonisolated static func state(
        trialStartedAt: Date?, hasValidLicense: Bool, now: Date
    ) -> LicenseState {
        if hasValidLicense { return .licensed }
        let days = daysLeft(trialStartedAt: trialStartedAt, now: now)
        return days > 0 ? .trialing(daysLeft: days) : .expired
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

    /// Dates cross the Keychain as ISO8601 strings.
    nonisolated static func encode(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    nonisolated static func decodeDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}

/// Parsers for the Lemon Squeezy License API's three endpoints.
///
/// A definitive answer ("activated", "refused: limit reached", "this key was
/// disabled") comes back as a value; anything that is *not* an answer —
/// malformed JSON, an HTML error page, a shape the API grew overnight —
/// throws, and callers treat a throw exactly like a network failure: the
/// stored state stands. A licensed user must never be demoted by a parse
/// error (rule 5's cousin: a failure we can't read is not a verdict).
enum LemonSqueezy {
    struct Activation: Equatable {
        var instanceID: String
        /// Lemon Squeezy test-mode keys report the **same** `store_id` as
        /// live ones (verified against the API 2026-08-22), so the store pin
        /// does not separate them and a test key unlocks a real build. Only
        /// the store owner can mint one, so this is not a hole — but it is
        /// worth saying out loud in Settings rather than having a build
        /// silently licensed by a key that was never paid for.
        var isTestMode: Bool
    }

    enum ActivationResult: Equatable {
        case activated(Activation)
        case refused(String)
    }

    enum ValidationResult: Equatable {
        case valid
        case invalid(reason: String)
    }

    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    private struct Envelope: Decodable {
        var activated: Bool?
        var valid: Bool?
        var deactivated: Bool?
        var error: String?
        var licenseKey: KeyInfo?
        var instance: Instance?
        var meta: Meta?

        struct KeyInfo: Decodable {
            var status: String?
            var testMode: Bool?

            enum CodingKeys: String, CodingKey {
                case status
                case testMode = "test_mode"
            }
        }
        struct Instance: Decodable {
            var id: String?
        }
        struct Meta: Decodable {
            var storeId: Int?

            // Decodable's synthesized keys match property names, and this
            // one decoding nil doesn't fail anything — it silently skips
            // the store pin. The test that exists for the pin caught it.
            enum CodingKeys: String, CodingKey {
                case storeId = "store_id"
            }
        }

        enum CodingKeys: String, CodingKey {
            case activated, valid, deactivated, error, instance, meta
            case licenseKey = "license_key"
        }
    }

    nonisolated static func activation(
        from data: Data, expectedStoreID: Int? = Licensing.expectedStoreID
    ) throws -> ActivationResult {
        let envelope = try decode(data)
        guard let activated = envelope.activated else {
            throw ParseError(
                description: "Response had no 'activated' field.")
        }
        guard activated else {
            return .refused(refusalMessage(envelope))
        }
        if let expected = expectedStoreID,
            let store = envelope.meta?.storeId, store != expected {
            return .refused(
                "That license key belongs to a different product, so it can't unlock Inbox & Chill."
            )
        }
        guard let instanceID = envelope.instance?.id, !instanceID.isEmpty
        else {
            throw ParseError(
                description:
                    "Activation succeeded but the response carried no instance id."
            )
        }
        return .activated(
            Activation(
                instanceID: instanceID,
                isTestMode: envelope.licenseKey?.testMode ?? false))
    }

    nonisolated static func validation(
        from data: Data, expectedStoreID: Int? = Licensing.expectedStoreID
    ) throws -> ValidationResult {
        let envelope = try decode(data)
        guard let valid = envelope.valid else {
            throw ParseError(description: "Response had no 'valid' field.")
        }
        guard valid else {
            return .invalid(reason: refusalMessage(envelope))
        }
        if let expected = expectedStoreID,
            let store = envelope.meta?.storeId, store != expected {
            return .invalid(
                reason:
                    "That license key belongs to a different product, so it can't unlock Inbox & Chill."
            )
        }
        return .valid
    }

    nonisolated static func deactivation(from data: Data) throws -> Bool {
        let envelope = try decode(data)
        guard let deactivated = envelope.deactivated else {
            throw ParseError(
                description: "Response had no 'deactivated' field.")
        }
        return deactivated
    }

    /// What a refusal means, in words the user can act on. Lemon Squeezy's
    /// own `error` string is decent when present; the key statuses get a
    /// sentence each because "disabled" on its own explains nothing.
    nonisolated static func refusalMessage(status: String?, error: String?)
        -> String
    {
        switch status {
        case "disabled":
            return
                "Lemon Squeezy reports this license was disabled — usually a refund or a revoked key. If that doesn't sound right, reply to your purchase email."
        case "expired":
            return
                "Lemon Squeezy reports this license has expired. If that doesn't sound right, reply to your purchase email."
        default:
            if let error, !error.isEmpty { return error }
            return
                "Lemon Squeezy didn't accept this license key. Check it against your purchase email and try again."
        }
    }

    private nonisolated static func refusalMessage(_ envelope: Envelope)
        -> String
    {
        refusalMessage(
            status: envelope.licenseKey?.status, error: envelope.error)
    }

    private nonisolated static func decode(_ data: Data) throws -> Envelope {
        do {
            return try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ParseError(
                description:
                    "Couldn't read the Lemon Squeezy response: \(error.localizedDescription)"
            )
        }
    }
}
