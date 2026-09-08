import KeyboardShortcuts
import OSLog
import SwiftData
import SwiftUI

@main
struct InboxAndChillApp: App {
    @State private var appState = AppState()
    // Created here, at App scope, which is what Sparkle's own SwiftUI guidance
    // does: the updater must outlive any one window, and a menu bar app has no
    // AppDelegate to hang it off.
    @State private var updates = UpdateController()
    // Same reasoning as `updates`: it installs process-wide handlers at
    // launch and reads what the previous run left behind, so it must outlive
    // any one window.
    @State private var diagnostics = DiagnosticsRecorder()

    init() {
        IntentContext.appState = appState
        // Started here rather than from a `.task` on the panel: with
        // `.menuBarExtraStyle(.window)` the panel's content is not built
        // until the user first clicks the icon, so a crash from the previous
        // run would go unread until then — and the run marker for *this* run
        // would never be written at all.
        diagnostics.start()
        KeyboardShortcuts.onKeyUp(for: .togglePanel) {
            // Toggling MenuBarExtra presentation programmatically: handled
            // via an AppKit lookup of our status bar button in PanelToggler.
            PanelToggler.toggle()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(appState)
                .environment(updates)
                .environment(diagnostics)
                .modelContainer(appState.container)
        } label: {
            MenuBarLabel(badgeText: appState.badgeText)
        }
        .menuBarExtraStyle(.window)

        Window("Inbox & Chill", id: "main") {
            MainWindowView()
                .environment(appState)
                .environment(updates)
                .environment(diagnostics)
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
                .environment(diagnostics)
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
///
/// SwiftUI owns the status item and offers no API to present its window, so
/// this finds the item's button and clicks it. The first build read a private
/// `statusItem` property off `NSStatusBarWindow` through KVC. That worked, and
/// it is exactly the non-public API use App Review rejects (guideline 2.5.1;
/// see `docs/app-store-plan.md`). The button itself is an `NSStatusBarButton`,
/// a public class, sitting in the view hierarchy of one of this process's own
/// windows — so a plain walk of `NSApp.windows` finds it with public API only.
/// This app has exactly one status item, so the first button found is ours.
///
/// Not measured here (2026-09-08, written on a Linux box): that the button is
/// reachable from the status bar window's root view. If the hotkey ever stops
/// toggling the panel, the `error` line below is the first thing to look for.
@MainActor
enum PanelToggler {
    static func toggle() {
        guard let button = statusBarButton() else {
            // Default level, not .info: this is the line to read when someone
            // says the hotkey does nothing, and .info may never reach disk.
            log.error(
                "hotkey: no NSStatusBarButton in any of \(NSApp.windows.count) windows; panel not toggled")
            return
        }
        button.performClick(nil)
    }

    /// The menu bar button SwiftUI created for the `MenuBarExtra`, or nil.
    static func statusBarButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            // Start from the window's root view rather than `contentView`:
            // where AppKit parents the button inside a status bar window is
            // not documented, and the root covers every possibility.
            var root = window.contentView
            while let superview = root?.superview { root = superview }
            if let button = firstStatusBarButton(in: root) { return button }
        }
        return nil
    }

    private static func firstStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = firstStatusBarButton(in: subview) { return button }
        }
        return nil
    }

    private static let log = AppLog.logger(.diagnostics)
}
