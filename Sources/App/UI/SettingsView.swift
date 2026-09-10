import KeyboardShortcuts
import SwiftUI

/// Settings shell.
///
/// Five tabs, split by *what the setting is about* rather than by when it was
/// added: General is the app itself (how you open it, how it updates, what
/// you paid), Notifications is everything that decides how loudly it reaches
/// you, Sources is per-connector — including each source's own setup, which
/// is why the Claude Code hooks now live in the local source's editor rather
/// than in General — and Diagnostics is what broke, which belongs next to the
/// sources whose failures it records rather than buried in About.
///
/// **Four tabs in the App Store build.** Without Updates, License and the
/// journal, General and Notifications each held two small sections, and
/// neither justified a page (Brandon, 2026-09-09); there the badge and banner
/// sections live inside General and the Notifications tab is gone. The
/// sections themselves are one view (`NotificationSections`) so the two
/// builds cannot drift.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            #if !APP_STORE
            NotificationsPane()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)
            #endif

            SourcesPane()
                .tabItem { Label("Sources", systemImage: "tray.2") }
                .tag(SettingsTab.sources)

            DiagnosticsPane()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .tag(SettingsTab.diagnostics)

            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 640, height: 480)
        // The welcome buttons ask for a tab from outside this window; the
        // request is consumed here so it cannot fire twice.
        .onAppear { consumeTabRequest() }
        .onChange(of: appState.requestedSettingsTab) { consumeTabRequest() }
    }

    private func consumeTabRequest() {
        guard let requested = appState.requestedSettingsTab else { return }
        selection = requested
        appState.requestedSettingsTab = nil
    }
}

/// The five tabs, addressable so a button elsewhere can land on one.
enum SettingsTab: Hashable, Sendable {
    case general, notifications, sources, diagnostics, about
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
            // Neither section exists in the App Store build: the store
            // delivers updates and is the checkout, so a toggle that can only
            // be disabled would be UI about a feature the app does not have.
            // (Brandon, 2026-09-08, on seeing exactly that toggle.)
            #if !APP_STORE
            UpdatesSection()
            // Hidden while the mechanic is off, so an alpha build shows no
            // trace of a product that isn't for sale yet.
            if Licensing.isEnforced {
                LicenseSection()
            }
            #else
            // The store build has no Notifications tab; its two sections
            // sit here instead. See the shell's doc comment.
            NotificationSections()
            #endif
        }
        .formStyle(.grouped)
    }
}

/// Everything that decides how loudly the queue reaches you: the menu bar
/// count, banners, and the written record.
struct NotificationsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            NotificationSections()
            #if !APP_STORE
            JournalSettingsSection()
            #endif
        }
        .formStyle(.grouped)
    }
}

/// The badge and banner sections. One view, used by the Notifications tab in
/// the direct build and by General in the App Store build.
struct NotificationSections: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Group {
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
        }
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
