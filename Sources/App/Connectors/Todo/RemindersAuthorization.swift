import EventKit
import Foundation

/// Whether macOS will let this app read Reminders, and what to say about it
/// before it ever asks.
///
/// Mirrors `MailAutomationAuthorization` deliberately, for the same reasons:
/// the wording is the part that has to be right, a test process cannot stand
/// up TCC, so every status mapping and every string lives here as pure code
/// and the one impure call sits in `RemindersAccess`.
///
/// **Two measured facts shape this** (2026-08-26, `docs/todo-sources-plan.md`):
///
/// 1. **No entitlement is required.** A Developer ID, hardened-runtime,
///    unsandboxed build with *zero* entitlements was granted full access. This
///    is the **opposite** of the Apple-events case in CLAUDE.md rule 2 — do
///    not "fix" a permission problem here by adding an entitlement. Release
///    ships exactly one entitlement and that should stay true.
///    `NSRemindersFullAccessUsageDescription` in Info.plist is still
///    mandatory, and its absence is a crash rather than a denial.
/// 2. **Reading the status never prompts.** `EKEventStore.authorizationStatus`
///    is free, which is what lets exactly one place in the app spend the
///    consent dialog — the same primitive
///    `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` gives
///    the Mail source.
enum RemindersAuthorization {

    /// Why Reminders can or can't be read, in the words the UI shows.
    enum Outcome: Equatable {
        /// Full access — reads and completions both work.
        case granted
        /// Nothing has asked macOS yet. Not an error, but the source cannot
        /// read anything until someone asks, so it must not look like one.
        case notRequested
        /// Asked and refused, or restricted by policy.
        case blocked(String)
        /// macOS granted something short of full access. Reminders has no
        /// write-only tier today, so this is the "shouldn't happen" branch —
        /// and it refuses rather than assuming, for the same reason
        /// `MailAutomationAuthorization` does.
        case insufficient(String)

        var message: String? {
            switch self {
            case .blocked(let message), .insufficient(let message): return message
            case .granted, .notRequested: return nil
            }
        }

        /// Why a poll must not go ahead, or `nil` when it may.
        ///
        /// This string is what replaces silence. Every case here would
        /// otherwise be an empty queue with nothing said about it — and with
        /// `.remoteTruth` an empty snapshot does not merely look wrong, it
        /// **archives every task row**. That is the Apple Mail `-1743` bug
        /// with a bigger blast radius.
        var fetchRefusal: String? {
            switch self {
            case .granted: return nil
            case .notRequested: return RemindersAuthorization.notRequestedAdvice
            case .blocked(let message), .insufficient(let message): return message
            }
        }

        var allowsFetch: Bool { self == .granted }
    }

    // MARK: Status mapping

    /// The verdict for an `EKAuthorizationStatus`.
    ///
    /// Pure, so the mapping is tested rather than trusted: this function
    /// decides whether the source polls at all, and every wrong answer it
    /// could give is silent.
    ///
    /// `.authorized` is the pre-macOS-14 spelling and still what the system
    /// reports on this Mac (measured: rawValue 3 after a successful full-access
    /// request), so it has to be accepted as equivalent to `.fullAccess`.
    /// Treating only `.fullAccess` as good enough would have made the source
    /// permanently empty on the very machine it was measured on.
    static func outcome(for status: EKAuthorizationStatus) -> Outcome {
        switch status {
        case .fullAccess, .authorized:
            return .granted
        case .notDetermined:
            return .notRequested
        case .denied:
            return .blocked(deniedMessage)
        case .restricted:
            return .blocked(restrictedMessage)
        case .writeOnly:
            return .insufficient(writeOnlyMessage)
        @unknown default:
            return .blocked(
                "macOS reported a Reminders permission state Inbox & Chill doesn't recognise (\(status.rawValue)). Until that's resolved this source can't show anything."
            )
        }
    }

    // MARK: Copy

    static let deniedMessage =
        "macOS won't let Inbox & Chill read your Reminders. Allow it under System Settings › Privacy & Security › Reminders. Until then this source will look permanently empty."

    static let declinedMessage =
        "Access to Reminders was declined, so this source can't show anything. You can turn it on under System Settings › Privacy & Security › Reminders."

    static let restrictedMessage =
        "Reminders access is blocked by a profile or parental control on this Mac, so this source can't show anything. That's a system policy, not something Inbox & Chill can ask past."

    static let writeOnlyMessage =
        "macOS granted only write access to Reminders, which isn't enough to read your list. Allow full access under System Settings › Privacy & Security › Reminders."

    /// The `.notRequested` wording for somewhere with no button in reach.
    /// The UI copy below is shorter on purpose — there the button is right
    /// beside it.
    static let notRequestedAdvice =
        "macOS hasn't been asked whether Inbox & Chill may read your Reminders yet, so this source can't show anything. Open Settings › Sources and press “Allow Reminders Access” to ask."

    static let notRequestedMessage = "Not asked yet, so there's nothing to show."

    /// The verdict once the *prompting* call has answered.
    ///
    /// Distinguished from `deniedMessage` because "you just clicked Don't
    /// Allow" and "this was refused at some point in the past" need different
    /// sentences even though macOS reports both as `.denied`.
    static func requestOutcome(for status: EKAuthorizationStatus) -> Outcome {
        status == .denied ? .blocked(declinedMessage) : outcome(for: status)
    }

    /// Deep link to Privacy & Security › Reminders.
    static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!

    // MARK: The pre-prompt explanation

    /// What the user reads *before* macOS's dialog appears.
    ///
    /// Structured rather than one blob so the tests can assert on the parts,
    /// and so each claim stays individually checkable against what
    /// `RemindersConnector` actually does. A reassurance that has drifted out
    /// of date is worse than none.
    struct Preflight: Equatable {
        var title: String
        var lead: String
        var bullets: [String]
        var promptNote: String
    }

    /// Two bullets, and they are the two the user cannot guess.
    ///
    /// This started at three bullets plus a four-sentence prompt note, on top
    /// of three setup steps and a four-paragraph source note — and between them
    /// they said "nothing leaves this Mac" three times and "macOS will ask, and
    /// it'll look empty if you decline" four times. Brandon, 2026-08-26:
    /// *"there is WAY too much copy in the Add/Edit Source screen for
    /// Reminders. There are multiple paragraphs of text that are essentially
    /// duplicates of each other."*
    ///
    /// What survived is the stuff that is load-bearing and unguessable: what it
    /// reads, and that `E` is not `C`. The privacy claim lives in the *title*
    /// now rather than being restated as a bullet, and the "macOS only asks
    /// once" warning is one clause instead of a paragraph — the button is
    /// directly beneath it, and `notRequestedMessage` covers the un-asked state.
    static let preflight = Preflight(
        title: "Your reminders stay on this Mac",
        lead:
            "Reads what you're due so it queues up beside everything else you owe.",
        bullets: [
            // True of fetch(): title, notes, due date, list name, priority.
            // Paired with the write claim, because saying what it reads
            // invites the question this answers.
            "Reads titles, notes, lists and due dates. Writes nothing unless you press C.",
            // True of the capability set: .completesTask, and no .markDone.
            // The one genuinely surprising behaviour in the whole source.
            "E dismisses without completing — only C ticks a reminder off in Reminders.",
        ],
        promptNote:
            "macOS asks once. Decline and this source stays empty."
    )
}

/// The one impure call. Kept apart from the mapping above so the mapping can
/// be tested, exactly like `MailAutomation` beside
/// `MailAutomationAuthorization`.
///
/// **Only `RemindersAccessControl` may pass `prompting: true`.** macOS shows
/// its consent dialog once, so whoever triggers it decides whether the user
/// ever understood what they were agreeing to. Adding a second prompting
/// caller is a regression even with good intentions — give the new thing its
/// own preflight instead.
@MainActor
enum RemindersAccess {
    /// The UI's own store.
    ///
    /// `EKEventStore` is not `Sendable`, so it cannot be shared with the
    /// connector's actor — each side keeps its own and they never exchange
    /// EventKit objects. That costs nothing that matters: TCC consent is
    /// per-process, so a grant obtained through this store is immediately
    /// visible to the connector's.
    static let store = EKEventStore()

    /// Free, and never prompts — measured. `authorizationStatus` is a type
    /// method that touches no store, so this is safe from any isolation.
    nonisolated static func status() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    /// The reminder list names, or empty when access hasn't been granted.
    static func listTitles() -> [String] {
        guard RemindersAuthorization.outcome(for: status()).allowsFetch else {
            return []
        }
        return store.calendars(for: .reminder)
            .map(\.title)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Reads the current permission state, and optionally asks for it.
    ///
    /// `prompting: false` is free and shows nothing — measured, not assumed.
    static func resolve(prompting: Bool) async -> RemindersAuthorization.Outcome {
        let current = status()
        guard prompting, current == .notDetermined else {
            return RemindersAuthorization.outcome(for: current)
        }
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            // The throw itself is not the verdict — re-read the status, which
            // is authoritative, and let the mapping name it.
            return RemindersAuthorization.requestOutcome(for: status())
        }
        return RemindersAuthorization.requestOutcome(for: status())
    }
}
