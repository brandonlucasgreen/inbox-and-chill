import AppKit
import SwiftUI

/// One key press, independent of where it came from.
///
/// The panel receives keys from two places — a local `NSEvent` monitor and
/// SwiftUI's `onKeyPress` — and both have to reach identical behaviour. Naming
/// the input once means the handler is written once, and it can be tested
/// without a window.
enum PanelKeyInput: Equatable {
    case up
    case down
    case left
    case right
    case enter
    case escape
    case backspace
    case character(Character)

    /// Virtual key codes, not characters. `charactersIgnoringModifiers` gives
    /// arrows as private-use unicode scalars that vary with keyboard layout;
    /// the key codes don't.
    init?(_ event: NSEvent) {
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .enter
        case 53: self = .escape
        case 51: self = .backspace
        default:
            guard let character = event.charactersIgnoringModifiers?.first,
                !character.isNewline
            else { return nil }
            self = .character(character)
        }
    }

    init?(_ press: KeyPress) {
        switch press.key {
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .return: self = .enter
        case .escape: self = .escape
        case .delete: self = .backspace
        default:
            guard let character = press.characters.first else { return nil }
            self = .character(character)
        }
    }
}

/// Where ↑/↓ land, as a pure function of the visible order.
///
/// Extracted from the view so it can be tested. The panel's selection bug was
/// never in this arithmetic — it was that the keys never arrived — but an
/// untestable private method is how it stayed invisible for two rounds.
enum PanelSelection {
    /// The uid to select after moving `delta` rows from `current`.
    ///
    /// Clamped rather than wrapping, so holding ↓ parks on the last row
    /// instead of teleporting back to the top. Returns `nil` only when there
    /// is nothing to select; callers should leave the selection alone then.
    static func next(from current: String?, in uids: [String], by delta: Int)
        -> String?
    {
        guard !uids.isEmpty else { return nil }
        guard let current, let position = uids.firstIndex(of: current) else {
            // No selection yet (or it was filtered away): enter from the end
            // the user is travelling towards.
            return delta > 0 ? uids.first : uids.last
        }
        let target = min(max(position + delta, 0), uids.count - 1)
        return uids[target]
    }
}

/// Delivers key presses to the panel off the event stream, before SwiftUI's
/// focus system sees them.
///
/// `MenuBarExtra(.window)` hands its content to a non-activating window that
/// SwiftUI owns, and two separate things then break keyboard control:
///
/// 1. Nothing in the panel is first responder until the user clicks, so
///    `onKeyPress` simply never fires.
/// 2. Once something *is* focused, SwiftUI spends ↑/↓ on moving focus between
///    focusable views — and the panel deliberately contains several zero-sized
///    ones for its ⌘-shortcuts — so the arrows are consumed before any
///    `onKeyPress` handler is consulted.
///
/// A local monitor sidesteps both: it sees `keyDown` for this app's windows
/// ahead of view dispatch, so the panel can claim the keys it wants and pass
/// everything else through untouched. Scoped to the panel's own window, so
/// Settings and the main window keep their normal behaviour.
struct PanelKeyCapture: NSViewRepresentable {
    /// Returns `true` when the panel consumed the press.
    var handle: (PanelKeyInput, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The closure captures view state, so it is stale by the next render.
        (nsView as? MonitorView)?.handle = handle
    }

    private final class MonitorView: NSView {
        var handle: ((PanelKeyInput, NSEvent.ModifierFlags) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                // Panel closed. Monitors are global to the app, so leaving one
                // installed would eat keys meant for Settings.
                removeMonitor()
                return
            }
            installMonitor()

            // The panel's window is not made key just by being shown, and an
            // accessory app is not frontmost when its menu bar item is
            // clicked — so without this the app never receives the keyDown at
            // all and the monitor has nothing to read.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.isVisible else { return }
                if !window.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self, let handle = self.handle,
                    event.window === self.window,
                    let input = PanelKeyInput(event)
                else { return event }
                // Returning nil swallows the event, which is what stops
                // SwiftUI from spending the arrows on focus movement.
                return handle(input, event.modifierFlags) ? nil : event
            }
        }

        private func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
