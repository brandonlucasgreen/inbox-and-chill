import SwiftData
import SwiftUI

/// The contract between the focused main window and the menu bar.
///
/// A `Commands` struct can't reach a view's `@State`, so `MainWindowView`
/// publishes this bundle of closures with
/// `.focusedSceneValue(\.triageActions, …)` and `MainWindowCommands` reads it
/// with `@FocusedValue(\.triageActions)`. When it is `nil` — no main window,
/// or the panel/Settings owns focus — every Queue and View item disables
/// itself, which is what keeps ⌘R/E/⌘P from firing into thin air.
///
/// `Equatable` deliberately compares only the value fields: closures can't be
/// compared, and `revision` (AppState.queueVersion) plus `selection` change
/// whenever the captured queue state could have gone stale, so SwiftUI never
/// keeps closures that would act on the wrong rows.
struct TriageActions {

    // MARK: State the menus read

    var scope: TriageScope
    /// Ordered scope list for the View menu, with ⌘-number assignments.
    var scopes: [ScopeShortcut]
    var selection: Set<PersistentIdentifier>
    var allSelectedPinned: Bool
    var canRestore: Bool
    /// True only when *every* selected row belongs to a source that can
    /// complete tasks. All-or-nothing rather than "some", because a partial
    /// completion across a mixed selection would be silently half-done.
    var canComplete: Bool
    var canUndoDone: Bool
    /// True while the search field owns the keyboard: plain-key equivalents
    /// (E for Done) must stand down so typing an "e" types an "e".
    var isSearchFocused: Bool
    /// `AppState.queueVersion` — invalidates the closures when the queue moves.
    var revision: Int

    // MARK: Commands

    var open: @MainActor () -> Void
    var openAndDone: @MainActor () -> Void
    var markDone: @MainActor () -> Void
    var completeTask: @MainActor () -> Void
    var snooze: @MainActor (SnoozePreset) -> Void
    var pickSnoozeDate: @MainActor () -> Void
    var togglePin: @MainActor () -> Void
    /// ⌘G — file the selection under a topic.
    var group: @MainActor () -> Void
    var restore: @MainActor () -> Void
    var copy: @MainActor () -> Void
    var undoDone: @MainActor () -> Void
    var refresh: @MainActor () -> Void
    var selectScope: @MainActor (TriageScope) -> Void

    // MARK: Derived

    var hasSelection: Bool { !selection.isEmpty }

    var canActOnSelection: Bool { hasSelection && !isSearchFocused }

    var pinTitle: String { allSelectedPinned ? "Unpin" : "Pin" }

    /// "Mark Done" vs "Mark 3 Done" — menu titles that admit multi-select.
    func title(_ verb: String, suffix: String = "") -> String {
        let tail = suffix.isEmpty ? "" : " \(suffix)"
        guard selection.count > 1 else { return verb + tail }
        return "\(verb) \(selection.count)\(tail)"
    }
}

extension TriageActions: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.scopes == rhs.scopes
            && lhs.selection == rhs.selection
            && lhs.allSelectedPinned == rhs.allSelectedPinned
            && lhs.canRestore == rhs.canRestore
            && lhs.canComplete == rhs.canComplete
            && lhs.canUndoDone == rhs.canUndoDone
            && lhs.isSearchFocused == rhs.isSearchFocused
            && lhs.revision == rhs.revision
    }
}

private struct TriageActionsKey: FocusedValueKey {
    typealias Value = TriageActions
}

extension FocusedValues {
    /// Set by `MainWindowView`; read by `MainWindowCommands`.
    var triageActions: TriageActions? {
        get { self[TriageActionsKey.self] }
        set { self[TriageActionsKey.self] = newValue }
    }
}
