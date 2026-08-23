import Foundation

/// Claude Code's hooks, specifically.
///
/// The machinery moved to `AgentHookInstaller` when Codex and Gemini were
/// added — all three take the same shape of config file and the same stdin
/// payload, so there is one implementation and three descriptions of it
/// (`AgentHooks`). This stays as the name the rest of the app and the tests
/// already use, and as the home for the parts that really are Claude Code's
/// alone: the meaning of its four events, and why they are the ones we pick.
///
/// **One queue row per session, not one per turn.** Every request addresses
/// `claude-<session_id>` — a session-stable id — so a session occupies
/// exactly one row for its whole life, updated in place. The original
/// convention gave `Stop` a timestamped id, which meant a fresh row at the
/// end of *every turn*: a thirty-turn session left thirty rows, and the one
/// fact worth keeping — this session is waiting on you — was buried in its
/// own duplicates.
///
///   - `Notification` — Claude wants the user (a permission prompt, or 60s
///     idle). Upserts the row, high-signal.
///   - `Stop` — a turn ended, so it is the user's move. Upserts the same row,
///     low-signal, carrying what Claude last said.
///   - `UserPromptSubmit` — the user replied. **Clears** the row. This is
///     what makes the queue mean "sessions awaiting my reply"; without it a
///     live session's row never leaves.
///   - `SessionEnd` — the session is gone. Clears the row.
///
/// `Stop` staying low-signal is deliberate: an ignored finish goes idle,
/// `Notification` re-fires ~60s later, and the same row turns high-signal, so
/// urgency rises with neglect without anything having to track neglect. Codex
/// has no idle event, which is the one place its mapping cannot follow.
enum ClaudeCodeIntegration {
    typealias IntegrationError = AgentHookInstaller.IntegrationError
    typealias InstallState = AgentHookInstaller.InstallState

    /// The Claude Code installer. Everything below delegates to it.
    static var installer: AgentHookInstaller { AgentHooks.claudeCode }

    static var installState: InstallState { installer.installState }
    static var isInstalled: Bool { installer.isInstalled }

    static var userDeclinedHooks: Bool {
        get { installer.userDeclined }
        set { installer.userDeclined = newValue }
    }

    static func installHooks() throws { try installer.installHooks() }
    static func uninstallHooks() throws { try installer.uninstallHooks() }

    static func hasAnyInchillEntry(in settings: [String: Any]) -> Bool {
        AgentHookInstaller.hasAnyInchillEntry(in: settings)
    }

    static func shellQuoted(_ path: String) -> String {
        AgentHookInstaller.shellQuoted(path)
    }

    nonisolated static func shouldAutoInstall(
        state: InstallState, userDeclined: Bool, hasEnabledLocalSource: Bool
    ) -> Bool {
        AgentHookInstaller.shouldAutoInstall(
            state: state, userDeclined: userDeclined,
            // Claude Code's own callers predate multi-harness support and
            // ask only about state; presence is the installer's business.
            harnessIsPresent: true,
            hasEnabledLocalSource: hasEnabledLocalSource)
    }

    nonisolated static func explainAutoInstallFailure(_ error: Error) -> String {
        AgentHookInstaller.explainAutoInstallFailure(
            error, displayName: "Claude Code",
            settingsLabel: "~/.claude/settings.json")
    }
}
