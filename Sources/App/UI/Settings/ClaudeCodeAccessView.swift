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

/// The Claude Code half of the local source: what it does, and the switch.
struct ClaudeCodeSection: View {
    var body: some View {
        Section("Claude Code") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Claude Code sessions post to this queue, so a session waiting on your reply shows up like any other item — and opening it jumps back to that session."
                )
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    "This is set up for you. It works through four hooks in ~/.claude/settings.json, because hooks are the only way Claude Code can tell another app what's happening. Nothing is installed on your Mac — the inchill command already lives inside this app — and your settings file is backed up first, with everything else in it left alone."
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
///
/// Three states now that installation is automatic, and the middle one is
/// the point: **off, because you turned it off** is not the same as **not
/// working**, and only the second is a problem to report.
struct ClaudeCodeIntegrationControl: View {
    @Environment(AppState.self) private var appState
    @State private var state = ClaudeCodeIntegration.installState
    @State private var declined = ClaudeCodeIntegration.userDeclinedHooks

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if declined {
                Text(
                    "Turned off, so Claude Code sessions won't appear in the queue."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Turn On") {
                    appState.enableClaudeCodeHooks()
                    refresh()
                }
                .help("Add the hooks back to ~/.claude/settings.json")
            } else if state == .installed {
                Label(
                    "Connected to Claude Code.", systemImage: "checkmark.circle"
                )
                .foregroundStyle(.green)
                Button("Turn Off") {
                    appState.disableClaudeCodeHooks()
                    refresh()
                }
                .help("Remove the inchill hooks from ~/.claude/settings.json")
            } else {
                // Not declined and not installed means the automatic write
                // failed — the app already tried, so the honest thing is the
                // reason plus a retry, not a "Set Up" button implying nobody
                // has tried yet.
                Text(
                    appState.claudeHooksProblem
                        ?? "Claude Code isn't connected, so its sessions won't appear in the queue."
                )
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    appState.enableClaudeCodeHooks()
                    refresh()
                }
            }
        }
        // Another app (or the user) can edit settings.json underneath a
        // long-lived Settings window, so re-read rather than trusting the
        // value this view was created with.
        .onAppear(perform: refresh)
    }

    private func refresh() {
        state = ClaudeCodeIntegration.installState
        declined = ClaudeCodeIntegration.userDeclinedHooks
    }
}

/// Hooks that should be there and aren't, said out loud in the Sources list.
///
/// The counterpart to `MailPermissionNotice`, and the same failure class: an
/// enabled local source with no hooks receives nothing, which looks exactly
/// like nobody having run Claude Code today (rule 5).
///
/// **Silent when the user turned the hooks off.** That state is a choice,
/// not a fault, and a banner about it would be nagging — the switch stays in
/// the source's editor for whenever they want it back.
struct ClaudeCodeHooksNotice: View {
    @Environment(AppState.self) private var appState
    @State private var state = ClaudeCodeIntegration.installState
    @State private var declined = ClaudeCodeIntegration.userDeclinedHooks

    var body: some View {
        Group {
            if appState.hasEnabledLocalSource, !declined, state != .installed {
                ClaudeCodeIntegrationControl()
                    .font(.caption)
            }
        }
        .onAppear {
            state = ClaudeCodeIntegration.installState
            declined = ClaudeCodeIntegration.userDeclinedHooks
        }
    }
}
