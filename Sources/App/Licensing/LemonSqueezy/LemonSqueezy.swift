import Foundation

/// The direct build's checkout: a Lemon Squeezy license key. Compiled into
/// the direct target only — the store target excludes `Licensing/LemonSqueezy`
/// whole, because a license key is a 2.4.5(vi) rejection and the checkout
/// URL a 3.1.1 one, and `scripts/verify-bundle.sh --app-store` greps the
/// store binary for `lemonsqueezy.com` to prove the exclusion held.
extension Licensing {
    static let price = "$15"

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

    // Keychain accounts beside `trialStartKey`.
    static let licenseKeyKey = "license.key"
    static let instanceIDKey = "license.instanceID"
    static let invalidReasonKey = "license.invalidReason"
    static let lastValidatedKey = "license.lastValidatedAt"
    static let testModeKey = "license.testMode"
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
