import Foundation
import Testing

@testable import InboxAndChill

/// The policy behind writing `~/.claude/settings.json` without being asked.
///
/// Pure, so it can be exercised without touching the real file — which
/// matters more here than usual: the thing under test is *when the app edits
/// a config it does not own*, and a test that got that wrong would edit the
/// developer's own Claude Code setup.
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
