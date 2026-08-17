import Foundation

/// Bridge from App Intents (Shortcuts, Spotlight, widgets…) to the app's
/// single live `AppState`. Intents run in-process here, but `AppState` is
/// created by the SwiftUI app struct after this enum exists, so the app's
/// `init()` must publish it once:
///
///     IntentContext.appState = appState
///
/// Weak so an intent invoked after the app has torn down its state (should
/// not normally happen for a menu bar app, but cheap insurance) fails softly
/// instead of dangling.
enum IntentContext {
    @MainActor static weak var appState: AppState?
}
