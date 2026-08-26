import CoreServices
import Foundation
import OSLog

/// The one impure half of the Mail permission story: asking macOS what it
/// thinks, and — only when told to — letting it ask the user.
///
/// Everything worth testing is in `MailAutomationAuthorization`; this file is
/// deliberately thin, because none of it can run in a test process (rule 6).
enum MailAutomation {
    static let mailBundleID = "com.apple.mail"

    private static let log = AppLog.logger(.appleMail)

    /// `typeWildCard` — '****'. Spelled numerically for the same reason the
    /// status codes are: it keeps this file readable next to
    /// `AppleMailConnector.explain`, which also uses the raw values.
    ///
    /// Wildcards ask the question the UI actually wants answered — "may this
    /// app drive Mail at all?" — rather than pre-judging which event the
    /// connector will send first.
    private static let wildcard: AEEventClass = 0x2a2a_2a2a

    /// Asks macOS whether Apple events to Mail are permitted.
    ///
    /// - Parameter prompting: `false` only *reads* the state and is safe to
    ///   call from anywhere, including a poll — it never shows a dialog.
    ///   `true` lets macOS show the Automation dialog, so pass it **only**
    ///   where the user has just pressed something they can connect the
    ///   dialog to. macOS spends this prompt once per app per target; there
    ///   is no second chance, and a prompt spent by a background poll is
    ///   the failure this whole file exists to prevent.
    static func resolve(prompting: Bool) async -> MailAutomationAuthorization.Outcome {
        let status = await permissionStatus(prompting: prompting)
        let outcome =
            prompting
            ? MailAutomationAuthorization.requestOutcome(forStatus: status)
            : MailAutomationAuthorization.outcome(forStatus: status)

        // Logged for the same reason the banner outcome is: this decides
        // whether a source shows anything, and every way it can go wrong
        // looks like an empty inbox from the outside.
        //
        // Levelled, though, because `fetch()` resolves on every poll — a
        // `.notice` per minute per Mail source would bury the one line that
        // matters. The prompting call happens at most a handful of times in
        // an install's life and is the one worth keeping.
        // Assembled as a plain String first: `privacy:` is OSLog's own
        // interpolation and is only legal inside a Logger call, so it cannot
        // appear here. Nothing in it is sensitive — a status code, a Bool and
        // a case name — hence `.public` at the one point that needs it.
        let message =
            "mail automation resolved: status=\(status) "
            + "prompted=\(prompting) outcome=\(String(describing: outcome))"
        if prompting {
            log.notice("\(message, privacy: .public)")
        } else {
            log.debug("\(message, privacy: .public)")
        }
        return outcome
    }

    /// The raw `OSStatus`, off the main thread.
    ///
    /// `AEDeterminePermissionToAutomateTarget` blocks — for as long as the
    /// user takes to answer, when it is allowed to ask — so it cannot run on
    /// the MainActor without freezing the UI behind the very dialog it just
    /// raised.
    private static func permissionStatus(prompting: Bool) async -> OSStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                let descriptor = NSAppleEventDescriptor(
                    bundleIdentifier: mailBundleID)
                // The pointer is owned by `descriptor`, so the call has to
                // happen inside its lifetime — otherwise this is a dangling
                // read that would work right up until it didn't.
                let status: OSStatus = withExtendedLifetime(descriptor) {
                    guard let target = descriptor.aeDesc else {
                        // No address descriptor means we cannot even form the
                        // question. Report it as the unrecognised case rather
                        // than as a denial: the advice for the two differs.
                        return -1
                    }
                    return AEDeterminePermissionToAutomateTarget(
                        target, wildcard, wildcard, prompting)
                }
                continuation.resume(returning: status)
            }
        }
    }

    /// Serial, and separate from `AppleMailConnector`'s script queue: a
    /// prompting call parks here until the user answers the dialog, and
    /// sharing the queue would stall an in-flight Mail read behind it.
    private static let queue = DispatchQueue(
        label: "lol.bgreen.inboxandchill.apple-mail.automation")
}
