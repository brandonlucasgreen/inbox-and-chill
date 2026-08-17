import KeyboardShortcuts
import SwiftData
import SwiftUI

@main
struct InboxAndChillApp: App {
    @State private var appState = AppState()

    init() {
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
            if let button = window.value(forKey: "statusItem")
                .flatMap({ $0 as? NSStatusItem })?.button {
                button.performClick(nil)
                return
            }
        }
    }
}
