import Foundation
import Testing

@testable import InboxAndChill

/// The policy behind writing `~/.claude/settings.json` without being asked.
///
/// Pure, so it can be exercised without touching the real file — which
/// matters more here than usual: the thing under test is *when the app edits
/// a config it does not own*, and a test that got that wrong would edit the
/// developer's own Claude Code setup.
/// The three agent CLIs, and the contracts that keep them from drifting
/// apart. Codex and Gemini were mapped from documentation and have never met
/// the real tools (rule 4), so these tests pin every part that *can* be
/// pinned without them: the id/kind namespacing, the shared vocabulary, and
/// the rule that the app never touches a config for a tool you don't have.
@Suite("Agent hook harnesses")
struct AgentHarnessTests {
    @Test func everyHarnessHasItsOwnIDsAndFiles() {
        let installers = AgentHooks.all
        #expect(installers.count == 3)
        #expect(Set(installers.map(\.id)).count == 3)
        #expect(Set(installers.map(\.settingsURL)).count == 3)
        #expect(Set(installers.map(\.subcommand)).count == 3)
    }

    /// Two agents running in the same folder must never share a queue row.
    @Test func queueIDsAreNamespacedPerHarness() {
        let ids = ClaudeHook.Harness.all.map {
            ClaudeHook.itemID(sessionID: "abc", harness: $0)
        }
        #expect(ids == ["claude-abc", "codex-abc", "gemini-abc"])
        #expect(Set(ids).count == 3)
    }

    /// Claude Code's ids and copy are what existing installs and rows already
    /// carry; generalising must not have reworded or re-prefixed them.
    @Test func claudeCodeIsUnchangedByGeneralisation() {
        #expect(ClaudeHook.itemID(sessionID: "s") == "claude-s")
        let waiting = ClaudeHook.request(for: .notification, sessionID: "s")
        #expect(waiting.title == "Claude Code needs your input")
        #expect(waiting.kind == "claude_waiting")
        let done = ClaudeHook.request(
            for: .stop, sessionID: "s", cwd: "/tmp/repo")
        #expect(done.title == "Claude finished in repo")
        #expect(done.kind == "claude_done")
        // The opt-out key must keep its original spelling, or anyone who
        // already pressed Remove would silently get hooks back.
        #expect(AgentHooks.claudeCode.userDeclinedKey == "claudeHooks.userDeclined")
    }

    /// `AppState.open` routes to the Claude session opener on a `claude`
    /// kind prefix. Codex and Gemini have no such deep link, so their kinds
    /// must NOT collide with that prefix or ⏎ would try to find a Claude
    /// session that does not exist.
    @Test func onlyClaudeKindsClaimTheClaudeSessionOpener() {
        for harness in ClaudeHook.Harness.all where harness.id != "claude" {
            let kind = ClaudeHook.request(
                for: .notification, sessionID: "s", harness: harness).kind
            #expect(kind?.hasPrefix("claude") == false)
        }
    }

    /// The app writes `inchill <subcommand> <argument>` into a config file;
    /// the CLI parses that argument back into a semantic event. If the two
    /// lists ever diverge, every hook silently fails with "unknown hook
    /// kind" — this is the only place both sides are visible at once.
    @Test func installerArgumentsMatchTheCLIVocabulary() {
        let vocabulary = Set(ClaudeHook.Event.allCases.map(\.rawValue))
        for installer in AgentHooks.all {
            #expect(Set(installer.events.map(\.argument)) == vocabulary)
            // Every semantic event mapped exactly once per harness.
            #expect(installer.events.count == vocabulary.count)
            #expect(
                ClaudeHook.Harness.named(installer.subcommand)?.id
                    == installer.id)
        }
    }

    /// Documented event names, pinned so a careless edit is visible in review
    /// rather than at runtime on a machine nobody here has.
    @Test func documentedEventNames() {
        func events(_ i: AgentHookInstaller) -> [String: String] {
            Dictionary(
                uniqueKeysWithValues: i.events.map { ($0.argument, $0.event) })
        }
        #expect(
            events(AgentHooks.codex) == [
                "notification": "PermissionRequest", "stop": "Stop",
                "user-prompt-submit": "UserPromptSubmit",
                "session-end": "SessionEnd",
            ])
        #expect(
            events(AgentHooks.gemini) == [
                "notification": "Notification", "stop": "AfterAgent",
                "user-prompt-submit": "BeforeAgent",
                "session-end": "SessionEnd",
            ])
    }

    /// The app must never bring `~/.codex` into existence for someone who
    /// has never run Codex — that is litter in a directory we don't own.
    @Test func absentHarnessesAreNeverWrittenTo() {
        #expect(
            !AgentHookInstaller.shouldAutoInstall(
                state: .notInstalled, userDeclined: false,
                harnessIsPresent: false, hasEnabledLocalSource: true))
        let everyPresentOneReallyExists = AgentHooks.present.allSatisfy {
            $0.isPresent
        }
        #expect(everyPresentOneReallyExists)
    }
}

@Suite("Claude Code hook auto-install policy")
struct ClaudeCodeAutoInstallTests {
    typealias Integration = ClaudeCodeIntegration

    @Test func installsWhenMissingOnFirstRun() {
        #expect(
            Integration.shouldAutoInstall(
                state: .notInstalled, userDeclined: false,
                hasEnabledLocalSource: true))
    }

    /// `.outdated` is our own entries pointing at a command we no longer
    /// write — usually the app moved — so rewriting repairs rather than adds.
    @Test func repairsOutdatedHooks() {
        #expect(
            Integration.shouldAutoInstall(
                state: .outdated, userDeclined: false,
                hasEnabledLocalSource: true))
    }

    @Test func doesNothingWhenAlreadyCurrent() {
        #expect(
            !Integration.shouldAutoInstall(
                state: .installed, userDeclined: false,
                hasEnabledLocalSource: true))
    }

    /// The guard the whole feature rests on: pressing Remove has to stay
    /// pressed. Without this, every launch would silently undo the one
    /// action the user took to say they didn't want the hooks — including
    /// re-adding them to a settings.json they had deliberately cleaned.
    @Test func neverUndoesAnExplicitRemoval() {
        #expect(
            !Integration.shouldAutoInstall(
                state: .notInstalled, userDeclined: true,
                hasEnabledLocalSource: true))
        #expect(
            !Integration.shouldAutoInstall(
                state: .outdated, userDeclined: true,
                hasEnabledLocalSource: true))
    }

    /// Someone who deleted the local source is not running Claude Code
    /// through this app, so editing their Claude config would be pure
    /// trespass.
    @Test func neverWritesWithoutAnEnabledLocalSource() {
        #expect(
            !Integration.shouldAutoInstall(
                state: .notInstalled, userDeclined: false,
                hasEnabledLocalSource: false))
    }

    /// Auto-installation has no sheet to keep open and no button to turn
    /// red, so the failure sentence is the only account the user ever gets:
    /// it must name the file and a way forward (rule 5).
    @Test func failureExplanationNamesTheFileAndAWayOut() {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "permission denied" }
        }
        let message = Integration.explainAutoInstallFailure(Boom())
        #expect(message.contains("~/.claude/settings.json"))
        #expect(message.contains("permission denied"))
        #expect(message.contains("retry"))
    }
}
