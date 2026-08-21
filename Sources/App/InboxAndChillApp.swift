import KeyboardShortcuts
import SwiftData
import SwiftUI

@main
struct InboxAndChillApp: App {
    @State private var appState = AppState()
    // Created here, at App scope, which is what Sparkle's own SwiftUI guidance
    // does: the updater must outlive any one window, and a menu bar app has no
    // AppDelegate to hang it off.
    @State private var updates = UpdateController()

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
                .environment(updates)
                .modelContainer(appState.container)
        } label: {
            MenuBarLabel(badgeText: appState.badgeText)
        }
        .menuBarExtraStyle(.window)

        Window("Inbox & Chill", id: "main") {
            MainWindowView()
                .environment(appState)
                .environment(updates)
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
        .commands { MainWindowCommands(updates: updates) }

        Settings {
            SettingsView()
                .environment(appState)
                .environment(updates)
                .modelContainer(appState.container)
        }
    }
}

struct MenuBarLabel: View {
    var badgeText: String?

    // Solid hand when something is waiting, hollow when the queue is empty --
    // the same read the tray glyphs used to carry. Both are template images,
    // so macOS tints them for the light or dark menu bar on its own.
    var body: some View {
        if let badgeText, badgeText != "●" {
            Image("MenuBarPeace")
            Text(badgeText)
        } else if badgeText == "●" {
            Image("MenuBarPeace")
        } else {
            Image("MenuBarPeaceOutline")
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
