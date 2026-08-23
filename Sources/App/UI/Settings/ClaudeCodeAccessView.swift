import SwiftUI

/// The Claude Code hooks, in the two places they belong: `ClaudeCodeSection`
/// in the local source's editor where that source is being set up, and
/// `ClaudeCodeHooksNotice` in the Sources list for every day after that.
/// Same shape as `MailAccessView`, and for the same reason — a source that
/// cannot receive anything must say so where the source lives.
///
/// **Why hooks at all?** Claude Code has no API, event stream, or daemon an
/// outside app can subscribe to, and nothing on the system can tell "waiting
/// for your reply" apart from "still thinking" by watching processes. Hooks
/// are its only supported extension point, and the hook is the one piece of
/// this app that runs *inside* the session — which is also what lets a queue
/// row know which session and terminal to jump back to. Nothing is installed
/// on the Mac: `inchill` already ships inside the app bundle, so this adds
/// four lines to `~/.claude/settings.json` (backed up first, unknown keys
/// preserved) and removing them puts the file back.

/// Setup for the Claude Code half of the local source.
struct ClaudeCodeSection: View {
    var body: some View {
        Section("Claude Code") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Claude Code sessions can post to this queue, so a session waiting on your reply shows up like any other item — and opening it jumps back to that session."
                )
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "That needs four hooks in ~/.claude/settings.json, because hooks are the only way Claude Code can tell another app what's happening. Nothing is installed on your Mac — the inchill command already lives inside this app. Your settings file is backed up first, and anything else in it is left alone."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                ClaudeCodeIntegrationControl()
            }
            .font(.callout)
            .padding(.vertical, 2)
        }
    }
}

/// The state line plus whatever action that state affords. Shared by the
/// editor section and the Sources-list notice so the two can never disagree
/// about what is actually in `~/.claude/settings.json`.
struct ClaudeCodeIntegrationControl: View {
    @State private var state = ClaudeCodeIntegration.installState
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .installed:
                Label(
                    "Claude Code hooks are installed.",
                    systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .outdated:
                Text(
                    "Hooks from an older version are installed. Update them to get one queue row per session instead of one per turn."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            case .notInstalled:
                Text(
                    "Not set up yet, so Claude Code sessions won't appear in the queue."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(actionTitle) { perform(removing: false) }
                    .help(actionHelp)
                if state != .notInstalled {
                    Button("Remove") { perform(removing: true) }
                        .help(
                            "Remove the inchill hooks from ~/.claude/settings.json"
                        )
                }
            }

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Another session (or the user) can edit settings.json underneath a
        // long-lived Settings window, so re-read rather than trusting the
        // value this view was created with.
        .onAppear { state = ClaudeCodeIntegration.installState }
    }

    private var actionTitle: String {
        switch state {
        case .notInstalled: "Set Up Integration"
        case .outdated: "Update Integration"
        case .installed: "Reinstall"
        }
    }

    private var actionHelp: String {
        switch state {
        case .installed:
            "Rewrite the hooks in ~/.claude/settings.json (a backup is made first)"
        default:
            "Add Notification/Stop/UserPromptSubmit/SessionEnd hooks to ~/.claude/settings.json (a backup is made first)"
        }
    }

    private func perform(removing: Bool) {
        do {
            if removing {
                try ClaudeCodeIntegration.uninstallHooks()
            } else {
                try ClaudeCodeIntegration.installHooks()
            }
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
        state = ClaudeCodeIntegration.installState
    }
}

/// Missing hooks, said out loud in the Sources list.
///
/// The counterpart to `MailPermissionNotice`, and the same failure class: an
/// enabled local source with no hooks receives nothing, which looks exactly
/// like nobody having run Claude Code today (rule 5). Silent once the hooks
/// are current, and silent entirely when no local source is enabled.
struct ClaudeCodeHooksNotice: View {
    @Environment(AppState.self) private var appState
    @State private var state = ClaudeCodeIntegration.installState

    var body: some View {
        Group {
            if appState.hasEnabledLocalSource, state != .installed {
                ClaudeCodeIntegrationControl()
                    .font(.caption)
            }
        }
        .onAppear { state = ClaudeCodeIntegration.installState }
    }
}
