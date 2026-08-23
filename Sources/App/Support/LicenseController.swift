import Foundation
import OSLog

/// Owns the trial clock and the Lemon Squeezy license: reads and writes the
/// Keychain, talks to the License API, and publishes one `LicenseState` for
/// the UI plus a callback for `AppState` to start or stop syncing on.
///
/// The math and the response parsing live in `Licensing`/`LemonSqueezy`
/// (pure, tested); this class is the I/O around them.
///
/// One rule shapes every network path here: **offline never demotes.** A
/// validation that can't complete — no network, Lemon Squeezy down, a
/// response we can't parse — leaves the stored state exactly as it was. Only
/// an explicit "this key is disabled/expired/not found" from the API takes a
/// license away.
@MainActor
@Observable
final class LicenseController {
    private(set) var state: LicenseState
    /// Red text for Settings — activation and validation problems, in words.
    private(set) var problem: String?
    private(set) var isActivating = false
    /// Fired when `state.allowsSync` flips: activation mid-run, or the trial
    /// running out under a live app (a menu bar app runs for weeks, so
    /// launch-time checks alone would miss the transition by days).
    var onSyncPermissionChange: ((Bool) -> Void)?

    /// Last four characters of the stored key, for the Settings state line.
    var keySuffix: String? {
        guard let key = Keychain.get(Licensing.licenseKeyKey) else {
            return nil
        }
        return String(key.suffix(4))
    }

    /// Why the stored key stopped counting, if the API rejected it.
    var storedInvalidReason: String? {
        Keychain.get(Licensing.invalidReasonKey)
    }

    /// DEBUG-only escape hatch for UI iteration, same pattern as
    /// `INCHILL_NO_FAKE`: `INCHILL_LICENSE_STATE=licensed|expired|trialing`
    /// (or `trialing:3`) freezes the state and skips Keychain and network.
    private let forcedState: LicenseState?
    private var clockTask: Task<Void, Never>?

    private static let log = Logger(
        subsystem: "lol.bgreen.inboxandchill", category: "license")

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        forcedState = Self.forced(from: environment)
        if let forcedState {
            state = forcedState
            return
        }
        // First launch of a trial-carrying build starts the clock — including
        // for anyone upgrading from 0.3.x, whose 14 days start now.
        if Keychain.get(Licensing.trialStartKey) == nil {
            _ = Keychain.set(
                Licensing.encode(.now), for: Licensing.trialStartKey)
        }
        state = Self.derive()
        Self.log.notice(
            "license state resolved: \(String(describing: self.state), privacy: .public)"
        )
        startClock()
        Task { await self.revalidateIfStale() }
    }

    // MARK: State

    private static func derive(now: Date = .now) -> LicenseState {
        let trialStart = Licensing.decodeDate(
            Keychain.get(Licensing.trialStartKey))
        let hasValidLicense =
            Keychain.get(Licensing.licenseKeyKey) != nil
            && Keychain.get(Licensing.invalidReasonKey) == nil
        return Licensing.state(
            trialStartedAt: trialStart, hasValidLicense: hasValidLicense,
            now: now)
    }

    /// Recomputes from the Keychain and fires the sync callback on a flip.
    private func refreshState() {
        guard forcedState == nil else { return }
        let previous = state
        state = Self.derive()
        guard state != previous else { return }
        Self.log.notice(
            "license state resolved: \(String(describing: self.state), privacy: .public)"
        )
        if state.allowsSync != previous.allowsSync {
            onSyncPermissionChange?(state.allowsSync)
        }
    }

    /// Hourly recompute so the day the trial ends is noticed the day it
    /// happens, not at the next relaunch.
    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                self.refreshState()
                await self.revalidateIfStale()
            }
        }
    }

    // MARK: Activation

    func activate(key: String) async {
        guard forcedState == nil else { return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isActivating = true
        defer { isActivating = false }
        do {
            let name = Host.current().localizedName ?? "Mac"
            let data = try await Self.post(
                "activate",
                form: ["license_key": key, "instance_name": name])
            switch try LemonSqueezy.activation(from: data) {
            case .activated(let activation):
                // Keychain.set is not discardable for a reason: a key that
                // silently failed to save looks licensed until the relaunch
                // that forgets it.
                if let failure = Keychain.set(key, for: Licensing.licenseKeyKey)
                    ?? Keychain.set(
                        activation.instanceID, for: Licensing.instanceIDKey) {
                    problem = failure
                    return
                }
                Keychain.delete(Licensing.invalidReasonKey)
                _ = Keychain.set(
                    Licensing.encode(.now), for: Licensing.lastValidatedKey)
                problem = nil
                refreshState()
            case .refused(let reason):
                problem = reason
            }
        } catch {
            problem = Self.unreachable(error)
        }
    }

    /// Frees this Mac's activation seat, then forgets the key locally. Local
    /// state is only cleared when Lemon Squeezy confirmed — otherwise the
    /// seat would stay spent with nothing here to show for it.
    func deactivate() async {
        guard forcedState == nil,
            let key = Keychain.get(Licensing.licenseKeyKey),
            let instanceID = Keychain.get(Licensing.instanceIDKey)
        else { return }
        do {
            let data = try await Self.post(
                "deactivate",
                form: ["license_key": key, "instance_id": instanceID])
            guard try LemonSqueezy.deactivation(from: data) else {
                problem =
                    "Lemon Squeezy declined to release this Mac's activation. Check the key in your Lemon Squeezy account, or reply to your purchase email."
                return
            }
            Keychain.delete(Licensing.licenseKeyKey)
            Keychain.delete(Licensing.instanceIDKey)
            Keychain.delete(Licensing.invalidReasonKey)
            Keychain.delete(Licensing.lastValidatedKey)
            problem = nil
            refreshState()
        } catch {
            problem = Self.unreachable(error)
        }
    }

    // MARK: Revalidation

    /// Re-checks a stored key at most once a day, best-effort. Also retries
    /// a key the API previously rejected — a re-enabled key should recover
    /// on its own rather than requiring re-entry.
    func revalidateIfStale() async {
        guard forcedState == nil,
            let key = Keychain.get(Licensing.licenseKeyKey),
            let instanceID = Keychain.get(Licensing.instanceIDKey)
        else { return }
        if let last = Licensing.decodeDate(
            Keychain.get(Licensing.lastValidatedKey)),
            Date.now.timeIntervalSince(last) < 24 * 3600 {
            return
        }
        do {
            let data = try await Self.post(
                "validate",
                form: ["license_key": key, "instance_id": instanceID])
            switch try LemonSqueezy.validation(from: data) {
            case .valid:
                Keychain.delete(Licensing.invalidReasonKey)
                _ = Keychain.set(
                    Licensing.encode(.now), for: Licensing.lastValidatedKey)
                refreshState()
            case .invalid(let reason):
                // The one path that takes a license away: an explicit no.
                _ = Keychain.set(reason, for: Licensing.invalidReasonKey)
                _ = Keychain.set(
                    Licensing.encode(.now), for: Licensing.lastValidatedKey)
                Self.log.error(
                    "license invalidated by validation: \(reason, privacy: .public)"
                )
                refreshState()
            }
        } catch {
            // Not a verdict. Log it and keep the stored state.
            Self.log.notice(
                "license revalidation skipped: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: Lemon Squeezy transport

    /// The License API is public: the key is the credential, no store API
    /// key exists in this app or this repo. Errors arrive as JSON with
    /// non-2xx statuses, so the body is parsed regardless of status and the
    /// parsers decide whether it was an answer.
    private static func post(_ endpoint: String, form: [String: String])
        async throws -> Data
    {
        var request = URLRequest(
            url: URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!
                .appending(path: endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(form).data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    nonisolated static func formBody(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encoded =
                    value.addingPercentEncoding(withAllowedCharacters: allowed)
                    ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }

    private static func unreachable(_ error: Error) -> String {
        "Couldn't reach Lemon Squeezy — check your connection and try again. (\(error.localizedDescription))"
    }

    private static func forced(from environment: [String: String])
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
