import SwiftUI

/// The coding-agent hooks, in the two places they belong: `AgentHooksSection`
/// in the local source's editor where that source is set up, and
/// `AgentHooksNotice` in the Sources list for every day after that. Same
/// shape as `MailAccessView`, and for the same reason — a source that cannot
/// receive anything must say so where the source lives.
///
/// **Why hooks at all?** None of these tools has an API, event stream or
/// daemon an outside app can subscribe to, and nothing on the system can tell
/// "waiting for your reply" apart from "still thinking" by watching
/// processes. Hooks are the only supported extension point any of them
/// offers, and the hook is the one piece of this app that runs *inside* the
/// session — which is also what lets a queue row know which session and
/// terminal to jump back to. Nothing is installed on the Mac: `inchill`
/// already ships inside the app bundle, so this adds a few lines to a config
/// file the tool already has (backed up first, unknown keys preserved).
///
/// Every app that watches these tools works this way — Vibe Island and
/// Bartender's NotchBar both write hooks into these same files, which is why
/// merging rather than overwriting is not optional.

/// Setup for the coding agents found on this Mac.
struct AgentHooksSection: View {
    private var installers: [AgentHookInstaller] { AgentHooks.present }

    var body: some View {
        Section("Coding Agents") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "A session waiting on your reply shows up like any other item, and opening it takes you back to where it's running."
                )
                .fixedSize(horizontal: false, vertical: true)

                if installers.isEmpty {
                    Text(
                        "None found yet. Claude Code, Codex CLI and Gemini CLI connect automatically once they're installed."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        "Set up for you. Each config file is backed up first, and everything else in it is left alone."
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    ForEach(installers) { installer in
                        Divider()
                        AgentHookControl(installer: installer)
                    }
                }
            }
            .font(.callout)
            .padding(.vertical, 2)
        }
    }
}

/// One agent's state line plus whatever that state affords. Shared by the
/// editor section and the Sources-list notice so the two can never disagree
/// about what is actually in the config file.
///
/// Three states, and the middle one is the point: **off, because you turned
/// it off** is not the same as **not working**, and only the second is a
/// problem to report.
struct AgentHookControl: View {
    @Environment(AppState.self) private var appState
    let installer: AgentHookInstaller

    @State private var state = AgentHookInstaller.InstallState.notInstalled
    @State private var declined = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if declined {
                Text("\(installer.displayName) — turned off.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn On") {
                    appState.enableHooks(installer)
                    refresh()
                }
                .help("Add the hooks back to \(installer.settingsLabel)")
            } else if state == .installed {
                Label(
                    "Connected to \(installer.displayName).",
                    systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Button("Turn Off") {
                    appState.disableHooks(installer)
                    refresh()
                }
                .help("Remove the inchill hooks from \(installer.settingsLabel)")
            } else {
                // Not declined and not installed means the automatic write
                // failed — the app already tried, so the honest thing is the
                // reason plus a retry, not a "Set Up" button implying nobody
                // has tried yet.
                Text(
                    appState.hookProblems[installer.id]
                        ?? "\(installer.displayName) isn't connected, so its sessions won't appear in the queue."
                )
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    appState.enableHooks(installer)
                    refresh()
                }
            }
        }
        // Another app (or the user) can edit these files underneath a
        // long-lived Settings window, so re-read rather than trusting the
        // value this view was created with.
        .onAppear(perform: refresh)
    }

    private func refresh() {
        state = installer.installState
        declined = installer.userDeclined
    }
}

/// Hooks that should be there and aren't, said out loud in the Sources list.
///
/// The counterpart to `MailPermissionNotice`, and the same failure class: an
/// enabled local source whose agent has no hooks receives nothing, which
/// looks exactly like nobody having run that agent today (rule 5).
///
/// **Silent when the user turned an agent off**, and silent for agents that
/// aren't installed. Those are choices and absences, not faults, and a banner
/// about either would be nagging — the switch stays in the source's editor.
struct AgentHooksNotice: View {
    @Environment(AppState.self) private var appState
    @State private var broken: [AgentHookInstaller] = []

    var body: some View {
        Group {
            if appState.hasEnabledLocalSource, !broken.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(broken) { installer in
                        AgentHookControl(installer: installer)
                    }
                }
                .font(.caption)
            }
        }
        .onAppear {
            broken = AgentHooks.present.filter {
                !$0.userDeclined && $0.installState != .installed
            }
        }
    }
}
