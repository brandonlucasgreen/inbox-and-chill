import AppKit
import SwiftUI

/// The first-launch welcome, as a window the app opens *itself*.
///
/// The first build declared it as a SwiftUI `Window` scene with
/// `.defaultLaunchBehavior(.presented)`. On a real first launch of this
/// accessory (LSUIElement) app nothing appeared: the unified log for that
/// process reads "No windows open yet" and never records a window being
/// made (2026-09-04, Brandon: *"the welcome popup doesn't proactively
/// popup"*). Whether that is the launch behaviour being ignored for agent
/// apps or the scene never realising, the fix is the same — stop asking
/// SwiftUI to present it and present it: an `NSWindow` hosting the same
/// SwiftUI content, ordered front explicitly, from `AppState` once launch
/// has settled. `PanelToggler` takes the same AppKit route for the same
/// reason.
@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    var isPresented: Bool { window != nil }

    func present(appState: AppState) {
        if let window {
            bringForward(window)
            return
        }
        let root = WelcomeWindowView(onDismiss: { [weak self] in self?.close() })
            .environment(appState)
            .modelContainer(appState.container)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = FirstRun.title
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        // The content paints the brand's navy edge to edge; the window's own
        // ground and the traffic lights' appearance have to agree with it,
        // or a light-mode Mac shows a pale title strip over a dark card.
        window.backgroundColor = Brand.navyNSColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        // The red close button is a valid answer too; tidy up after it.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        self.window = window
        bringForward(window)
    }

    /// An accessory app's window lands behind whatever is frontmost unless
    /// the app is made regular and activated first — the same two steps the
    /// ⌘0 window takes in its `onAppear`.
    private func bringForward(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
        didClose()
    }

    private func didClose() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        window = nil
        // Back to a menu bar app — unless the ⌘0 window is up, which owns
        // the regular policy while it is open.
        if !NSApp.windows.contains(where: {
            $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true
        }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
