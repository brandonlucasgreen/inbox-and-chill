import KeyboardShortcuts
import SwiftUI

/// Settings shell (M0). Real panes land with their features.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        TabView {
            Form {
                Picker("Menu bar badge", selection: $state.badgeStyle) {
                    Text("High-signal count").tag(BadgeStyle.highSignalCount)
                    Text("Total count").tag(BadgeStyle.totalCount)
                    Text("Dot").tag(BadgeStyle.dot)
                    Text("None").tag(BadgeStyle.none)
                }
                // The per-source badge opt-out lives in the Sources tab (one
                // checkbox per row), which is the right home for it but means
                // someone configuring the badge here has no idea it exists.
                Text(
                    "Choose which sources count toward the badge in the Sources tab."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                KeyboardShortcuts.Recorder(
                    "Show panel:", name: .togglePanel)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                if let error = appState.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Play sound with banners", isOn: $state.bannerSound)
                Section {
                    ClaudeCodeIntegrationRow()
                }
                JournalSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            SourcesPane()
                .tabItem { Label("Sources", systemImage: "tray.2") }
        }
        .frame(width: 640, height: 480)
    }
}

/// One-click Claude Code hooks install (decision §2.1: local sources are a
/// first-class feature; hooks make Claude-waiting items appear automatically).
struct ClaudeCodeIntegrationRow: View {
    @State private var installed = ClaudeCodeIntegration.isInstalled
    @State private var errorText: String?

    var body: some View {
        LabeledContent("Claude Code") {
            Button(installed ? "Remove Integration" : "Set Up Integration") {
                do {
                    if installed {
                        try ClaudeCodeIntegration.uninstallHooks()
                    } else {
                        try ClaudeCodeIntegration.installHooks()
                    }
                    errorText = nil
                } catch {
                    errorText = String(describing: error)
                }
                installed = ClaudeCodeIntegration.isInstalled
            }
            .help(
                installed
                    ? "Remove the inchill hooks from ~/.claude/settings.json"
                    : "Add Notification/Stop hooks to ~/.claude/settings.json (a backup is made first)"
            )
        }
        if let errorText {
            Text(errorText).font(.caption).foregroundStyle(.red)
        }
    }
}


/// Journal export: append arrivals and triage actions to a Markdown file,
/// typically an Obsidian daily note, so an agent (or you) can reflect on what
/// came in and what you did about it.
struct JournalSettingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Section("Journal") {
            Toggle("Append activity to a Markdown file", isOn: $state.journalEnabled)

            if appState.journalEnabled {
                TextField(
                    "File", text: $state.journalPath,
                    prompt: Text("~/Vault/daily-notes/{{YYYY}}-{{MM}}-{{DD}}.md"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .help(
                        "Absolute path. {{YYYY}}, {{MM}} and {{DD}} are replaced with today's date — the same tokens Obsidian's daily notes use. Folders are created if missing.")

                TextField(
                    "Heading", text: $state.journalHeading,
                    prompt: Text("## Inbox & Chill"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .help(
                        "Entries are appended under this heading, so they sit tidily inside a templated daily note. Created at the end of the file if it isn't there.")

                Toggle("Log items when they arrive", isOn: $state.journalLogArrivals)
                Toggle(
                    "Log what you do with them (done, snoozed, pinned)",
                    isOn: $state.journalLogActions)

                if let error = appState.journalError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if appState.journalPath.trimmingCharacters(
                    in: .whitespaces).isEmpty {
                    Text("Set a file path to start writing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
