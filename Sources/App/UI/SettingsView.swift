import KeyboardShortcuts
import SwiftUI

/// Settings shell.
///
/// Four tabs, split by *what the setting is about* rather than by when it was
/// added: General is the app itself (how you open it, how it updates, what
/// you paid), Notifications is everything that decides how loudly it reaches
/// you, Sources is per-connector — including each source's own setup, which
/// is why the Claude Code hooks now live in the local source's editor rather
/// than in General.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }

            NotificationsPane()
                .tabItem { Label("Notifications", systemImage: "bell") }

            SourcesPane()
                .tabItem { Label("Sources", systemImage: "tray.2") }

            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 480)
    }
}

/// The app itself: how you summon it, whether it starts with the Mac, how it
/// updates, and what you paid for it.
struct GeneralPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section {
                KeyboardShortcuts.Recorder("Show panel:", name: .togglePanel)
                Toggle("Launch at login", isOn: $state.launchAtLogin)
                if let error = appState.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            UpdatesSection()
            // Hidden while the mechanic is off, so an alpha build shows no
            // trace of a product that isn't for sale yet.
            if Licensing.isEnforced {
                LicenseSection()
            }
        }
        .formStyle(.grouped)
    }
}

/// Everything that decides how loudly the queue reaches you: the menu bar
/// count, banners, and the written record.
struct NotificationsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("Menu Bar Badge") {
                Toggle("Badge: total waiting", isOn: $state.badgeShowsTotal)
                Toggle(
                    "Badge: high-signal only",
                    isOn: $state.badgeShowsHighSignal)
                // Two things are invisible from here: what "high signal"
                // actually means (each connector decides — an ntfy message at
                // the default priority 3 is not high signal, and a Slack
                // keyword hit never is), and that the per-source opt-out lives
                // one tab over.
                Text(
                    "Both on reads as total • high-signal, e.g. 6 • 2. High signal is what each source treats as someone specifically wanting you — mentions, review requests, DMs, and ntfy messages sent at priority 4 or 5. A counter showing zero is left off, and with both switched off the icon stays bare. Choose which sources count at all in the Sources tab."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Banners") {
                Toggle("Play sound with banners", isOn: $state.bannerSound)
                Text(
                    "Banners are off until you switch them on for a source, in the Sources tab."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                BannerPermissionNotice()
            }

            JournalSettingsSection()
        }
        .formStyle(.grouped)
    }
}

/// Permission trouble, said out loud.
///
/// Banners are the one feature whose failure the app cannot see for itself:
/// macOS accepts the posting call and drops it. This is where the user finds
/// out that a banner they switched on never had a chance of arriving.
struct BannerPermissionNotice: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.hasBannerEnabledSource {
            switch appState.bannerAuthorization {
            case .blocked(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Open Notification Settings") {
                        NSWorkspace.shared.open(
                            BannerAuthorization.systemSettingsURL)
                    }
                }
            case .notRequested:
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "macOS hasn't been asked for permission to show banners yet, so none can arrive."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Request Permission") {
                        Task {
                            await appState.resolveBannerAuthorization(
                                prompting: true)
                        }
                    }
                }
            default:
                EmptyView()
            }
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
