import Foundation

/// Whether macOS will let this app send Apple events to Mail, and what to say
/// about it before it ever asks.
///
/// Mirrors `BannerAuthorization` on purpose, for the same reason: the wording
/// is the part that has to be right, a test process cannot stand up TCC, so
/// every status mapping and every string lives here as pure code and the one
/// impure call sits in `MailAutomation`.
///
/// **Why this exists.** Before it, the first thing a new Apple Mail source did
/// was fire an Apple event from a background poll. macOS then threw its
/// Automation dialog at the user in Apple's own words, out of nowhere, up to
/// 60 seconds after they last touched the app — and on a cold Mail, ~12
/// seconds later again. "Don't Allow" is the safe-feeling answer to an
/// unexplained dialog, and the refusal that follows (-1743) looks exactly like
/// an empty inbox: rule 5's failure mode, and the shape of the 0.3.0 bug in
/// rule 2. So the order is now: explain, then ask only because the user
/// pressed a button, and never let a poll spend the one prompt macOS gives.
enum MailAutomationAuthorization {

    /// Why Mail can or can't be read, in the words the UI shows.
    enum Outcome: Equatable {
        /// macOS will deliver the Apple events.
        case granted
        /// Nothing has asked macOS yet. Not an error — but the source cannot
        /// read anything until someone asks, so it must not look like one.
        case notRequested
        /// Asked and refused, with the reason to show.
        case blocked(String)
        /// Mail isn't running, so macOS won't answer the question at all.
        /// Not a permission verdict and must not be shown as one.
        case mailNotRunning

        /// The red-text message, or `nil` when there is nothing wrong to say.
        var message: String? {
            if case .blocked(let message) = self { return message }
            return nil
        }

        /// Why a poll must not go ahead, or `nil` when it may.
        ///
        /// This is the string that replaces the old silence. Every case here
        /// used to be an empty queue with nothing said about it.
        var fetchRefusal: String? {
            switch self {
            case .granted:
                return nil
            case .notRequested:
                return MailAutomationAuthorization.notRequestedAdvice
            case .blocked(let message):
                return message
            case .mailNotRunning:
                return MailAutomationAuthorization.mailNotRunningMessage
            }
        }

        /// Whether a poll may go ahead.
        ///
        /// Only `.granted` qualifies, which includes declining to fetch when
        /// Mail is closed. That is deliberate: `tell application "Mail"`
        /// *launches* Mail, and a launch from a background poll is the last
        /// remaining path to an Automation dialog the user cannot connect to
        /// anything they did. Declining also matches what the source already
        /// told people — `AppleMailConnector.explain(-600)` says to open Mail
        /// and wait for the next refresh — so nothing here contradicts it.
        var allowsFetch: Bool { self == .granted }
    }

    // MARK: Status mapping

    // Spelled as literals rather than `errAEEventNotPermitted` and friends,
    // matching `AppleMailConnector.explain(appleScriptError:)`, which already
    // switches on the numbers. The symbol names are in the comments so the
    // numbers stay searchable both ways.
    /// `noErr`
    static let granted: OSStatus = 0
    /// `errAEEventNotPermitted` — asked, refused.
    static let notPermitted: OSStatus = -1743
    /// `errAEEventWouldRequireUserConsent` — never asked; asking would prompt.
    static let wouldRequireConsent: OSStatus = -1744
    /// `procNotFound` — Mail isn't running.
    static let procNotFound: OSStatus = -600
    /// `connectionInvalid` — Mail went away mid-question.
    static let connectionInvalid: OSStatus = -609

    /// The verdict for a status from `AEDeterminePermissionToAutomateTarget`.
    ///
    /// Pure, so the mapping is tested rather than trusted — this is the
    /// function that decides whether a source polls at all, and every wrong
    /// answer it could give is silent.
    static func outcome(forStatus status: OSStatus) -> Outcome {
        switch status {
        case Self.granted:
            return .granted
        case Self.wouldRequireConsent:
            return .notRequested
        case Self.notPermitted:
            return .blocked(deniedMessage)
        case Self.procNotFound, Self.connectionInvalid:
            return .mailNotRunning
        default:
            // An unrecognised status is not a licence to assume access, for
            // the same reason `BannerAuthorization` refuses to assume
            // delivery: the failure would be an empty queue with no reason.
            return .blocked(
                "macOS reported a permission state Inbox & Chill doesn't recognise when asking whether it may read Mail (error \(status)). Until that's resolved this source can't show anything."
            )
        }
    }

    // MARK: Copy

    /// Kept identical in substance to `AppleMailConnector.explain(-1743)`,
    /// which says the same thing when a live poll hits the refusal. Two
    /// wordings for one condition is how a user ends up thinking they have
    /// two problems.
    static let deniedMessage =
        "macOS won't let Inbox & Chill read Mail. Allow it under System Settings › Privacy & Security › Automation › Inbox & Chill › Mail. Until then this source will look permanently empty."

    static let declinedMessage =
        "Permission to read Mail was declined, so this source can't show anything. You can turn it on under System Settings › Privacy & Security › Automation › Inbox & Chill › Mail."

    /// The `.notRequested` wording for somewhere with no button in reach —
    /// a source's status message, most of the time. The UI copy below is
    /// deliberately shorter, because there the button is right beside it and
    /// sending someone to go find it would be silly.
    static let notRequestedAdvice =
        "macOS hasn't been asked whether Inbox & Chill may read Mail yet, so this source can't show anything. Open Settings › Sources and press “Allow Mail Access” to ask."

    static let notRequestedMessage =
        "macOS hasn't been asked whether Inbox & Chill may read Mail yet, so this source can't show anything."

    static let mailNotRunningMessage =
        "Mail isn't running, so there's nothing to read yet. Open Mail and this source fills in on the next refresh."

    /// The verdict once the prompting call has answered. Distinguished from
    /// `deniedMessage` because "you just clicked Don't Allow" and "this was
    /// refused at some point in the past" need different sentences even
    /// though macOS reports both as -1743.
    static func requestOutcome(forStatus status: OSStatus) -> Outcome {
        status == Self.notPermitted ? .blocked(declinedMessage) : outcome(forStatus: status)
    }

    /// Deep link to Privacy & Security › Automation.
    ///
    /// Duplicated from `ClaudeSessionTarget.systemSettingsAutomationURL`
    /// rather than shared: PLAN §2.1.10 established that `Connectors/Local/`
    /// is separable from the rest of the app, and a one-line URL is a cheaper
    /// thing to repeat than that coupling is to keep.
    static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    // MARK: The pre-prompt explanation

    /// What the user reads *before* macOS's dialog appears.
    ///
    /// Structured rather than one blob so the tests can assert on the parts,
    /// and so the claims stay individually checkable against
    /// `AppleMailConnector.fetchScript` and `markDoneScript` — every line
    /// below is a statement about what those two actually do, and a
    /// reassurance that drifts out of date is worse than none.
    struct Preflight: Equatable {
        var title: String
        var lead: String
        var bullets: [String]
        var promptNote: String
        var coldNote: String
    }

    /// Three bullets, and they are the three the user cannot guess.
    ///
    /// Trimmed from ~150 words to ~70 on 2026-09-05, alongside the same cut
    /// across every source editor. The claims are unchanged — each is a
    /// statement about what `fetchScript` and `markDoneScript` really do,
    /// and `preflightSaysTheLoadBearingThings` pins them — only the words
    /// around them went. Reminders got this treatment first, on 2026-08-26.
    static let preflight = Preflight(
        title: "Reading your mail stays on this Mac",
        lead:
            "Queues the messages you've flagged or haven't read, beside everything else you owe a reply.",
        bullets: [
            // True of fetchScript: it reads id, message id, subject, sender,
            // date received, flag and read state, account and mailbox name.
            "Reads each message's subject, sender and date — never the body.",
            // True of markDoneScript: sets read status, and clears the flag
            // only when a flag is what queued the row.
            "Sends and deletes nothing. Done marks a message read, and unflags it if a flag queued it.",
            // True of the connector as a whole: no network path exists in it.
            "Nothing leaves this Mac — it's reading the Mail app already on your dock.",
        ],
        promptNote:
            "macOS asks once. Decline and this source stays empty.",
        coldNote:
            "The first read after Mail has been idle takes about ten seconds.")
}
