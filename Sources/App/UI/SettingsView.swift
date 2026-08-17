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
                KeyboardShortcuts.Recorder(
                    "Show panel:", name: .togglePanel)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                Section {
                    ClaudeCodeIntegrationRow()
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            SourcesPane()
                .tabItem { Label("Sources", systemImage: "tray.2") }
        }
        .frame(width: 520, height: 400)
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
