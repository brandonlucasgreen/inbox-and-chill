import SwiftUI

// In `Journal/` beside the writer and the `AppState` extension it binds to, so
// the App Store build can leave the whole folder out (docs/app-store-plan.md).

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
