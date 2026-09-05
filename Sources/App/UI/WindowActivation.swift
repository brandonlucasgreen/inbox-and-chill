import AppKit
import SwiftUI

/// Bringing one of our windows forward is a two-step problem in an accessory
/// (LSUIElement) app: `openWindow`/`openSettings` order the window in, but
/// the *app* isn't active, so the window lands behind the frontmost app and
/// never becomes key. `NSApp.activate` alone isn't enough either — under
/// macOS 14+ cooperative activation the window may not exist yet on the
/// runloop turn the button action runs. So: activate, then retry
/// `makeKeyAndOrderFront` over a few turns until the window materialises.
@MainActor
enum WindowActivation {
    /// The ⌘0 triage window (`Window(id: "main")`).
    static func focusMainWindow() {
        // The window's onAppear flips the activation policy to .regular, but
        // only on first appearance — flip it here too so re-focusing an
        // already-open window that fell behind still works.
        NSApp.setActivationPolicy(.regular)
        focus { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// Opens the Settings scene the way the app menu's "Settings…" item does.
    /// For a view hosted in a plain `NSWindow` (the welcome), the SwiftUI
    /// `openSettings` environment action may have nothing behind it; this is
    /// the AppKit route it resolves to. Harmless when Settings is already up.
    static func openSettings() {
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector((name)), to: nil, from: nil) { return }
        }
    }

    /// The Settings scene window (SwiftUI names it
    /// "com_apple_SwiftUI_Settings_window"; match loosely so an OS rename
    /// degrades to the title check instead of a dead button).
    static func focusSettings() {
        focus {
            $0.identifier?.rawValue.contains("Settings") == true
                || $0.title.localizedCaseInsensitiveContains("settings")
        }
    }

    private static func focus(
        attempt: Int = 0, matching: @escaping (NSWindow) -> Bool
    ) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: matching) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focus(attempt: attempt + 1, matching: matching)
        }
    }
}
