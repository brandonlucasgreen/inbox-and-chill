import KeyboardShortcuts
import SwiftData
import SwiftUI

@main
struct InboxAndChillApp: App {
    @State private var appState = AppState()

    init() {
        IntentContext.appState = appState
        KeyboardShortcuts.onKeyUp(for: .togglePanel) {
            // Toggling MenuBarExtra presentation programmatically:
            // handled via AppKit lookup of our status window in PanelToggler.
            PanelToggler.toggle()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(appState)
                .modelContainer(appState.container)
        } label: {
            MenuBarLabel(badgeText: appState.badgeText)
        }
        .menuBarExtraStyle(.window)

        Window("Inbox & Chill", id: "main") {
            MainWindowView()
                .environment(appState)
                .modelContainer(appState.container)
                // LSUIElement apps have no Dock icon or ⌘Tab entry — while
                // the triage window is open, become a regular app so it
                // stays reachable; revert when it closes.
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .defaultLaunchBehavior(.suppressed)
        .commands { MainWindowCommands() }

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(appState.container)
        }
    }
}

struct MenuBarLabel: View {
    var badgeText: String?

    var body: some View {
        if let badgeText, badgeText != "●" {
            Image(systemName: "tray.full")
            Text(badgeText)
        } else if badgeText == "●" {
            Image(systemName: "tray.full.fill")
        } else {
            Image(systemName: "tray")
        }
    }
}

/// AppKit shim to toggle the MenuBarExtra window from the global hotkey.
@MainActor
enum PanelToggler {
    static func toggle() {
        // The MenuBarExtra's status item is owned by SwiftUI; simulate a
        // click on our status item to toggle the panel.
        for window in NSApp.windows
        where window.className.contains("NSStatusBarWindow") {
            // Private accessor — guard so a future rename degrades to a
            // silent no-op instead of an uncatchable KVC exception.
            guard window.responds(to: NSSelectorFromString("statusItem"))
            else { continue }
            if let button = window.value(forKey: "statusItem")
                .flatMap({ $0 as? NSStatusItem })?.button {
                button.performClick(nil)
                return
            }
        }
    }
}
