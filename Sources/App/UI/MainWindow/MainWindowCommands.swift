import SwiftUI

/// Menu bar commands for the main window (§5.2): every triage action is a real
/// menu item with a visible shortcut, not just a hidden key handler.
///
/// Wire it with `.commands { MainWindowCommands() }` on the `WindowGroup`.
/// It reaches the focused window through `@FocusedValue(\.triageActions)` and
/// every item disables itself when that value is missing — no main window, or
/// the panel/Settings owns focus — so the shortcuts fall back to whatever else
/// wants them (⌘C to the search field, ⌘Z to the field editor's undo).
@MainActor
struct MainWindowCommands: Commands {
    @FocusedValue(\.triageActions) private var actions

    /// Passed in rather than read from the environment: `Commands` bodies are
    /// not part of the view hierarchy, so `@Environment` does not reach them.
    let updates: UpdateController

    var body: some Commands {
        // The Mac-standard slot for this is the app menu, right under About.
        // It is only on screen while the triage window is open — an accessory
        // app has no menu bar otherwise — which is why Settings carries the
        // same controls rather than deferring to this.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
        }
        CommandMenu("Queue") { queueMenu }
        CommandGroup(after: .sidebar) { scopeMenu }
    }

    // MARK: Queue

    @ViewBuilder private var queueMenu: some View {
        openCommands
        Divider()
        triageCommands
        Divider()
        pasteboardCommands
        Divider()
        Button("Refresh All Sources") { actions?.refresh() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(actions == nil)
    }

    @ViewBuilder private var openCommands: some View {
        Button(label("Open", suffix: "Selected")) { actions?.open() }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!canAct)
        Button(label("Open", suffix: "and Mark Done")) {
            actions?.openAndDone()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canAct)
    }

    @ViewBuilder private var triageCommands: some View {
        Button(label("Mark", suffix: "Done")) { actions?.markDone() }
            // Bare E, as in the panel. Disabled while the search field has
            // focus so typing an "e" stays an "e".
            .keyboardShortcut("e", modifiers: [])
            .disabled(!canAct)
        // Bare C, matching the panel. Distinct from Mark Done on purpose: for
        // a to-do, "I've seen this" and "I've done this" are different facts,
        // and only this one writes to the source. Hidden rather than disabled
        // when the selection can't be completed — see the row buttons.
        if actions?.canComplete == true {
            Button(label("Complete", suffix: "Task")) { actions?.completeTask() }
                .keyboardShortcut("c", modifiers: [])
                .disabled(!canAct)
        }
        Menu("Snooze") {
            ForEach(SnoozePreset.allCases) { preset in
                Button("\(preset.title) (\(preset.detail))") {
                    actions?.snooze(preset)
                }
            }
            Divider()
            Button("Pick Date…") { actions?.pickSnoozeDate() }
        }
        .disabled(!canAct)
        Button(label(actions?.pinTitle ?? "Pin")) { actions?.togglePin() }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!canAct)
        Button(label("Restore", suffix: "to Queue")) { actions?.restore() }
            .disabled(!(actions?.canRestore ?? false))
    }

    @ViewBuilder private var pasteboardCommands: some View {
        Button(label("Copy")) { actions?.copy() }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!canAct)
        Button("Undo Done") { actions?.undoDone() }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(actions?.canUndoDone ?? false))
    }

    // MARK: View → scopes (⌘1…⌘9)

    @ViewBuilder private var scopeMenu: some View {
        Divider()
        ForEach(actions?.scopes ?? []) { choice in
            Toggle(isOn: scopeBinding(choice.scope)) {
                Label(choice.title, systemImage: choice.systemImage)
            }
            .keyboardShortcut(shortcut(for: choice))
            .disabled(actions == nil)
        }
    }

    // MARK: Helpers

    private var canAct: Bool { actions?.canActOnSelection ?? false }

    /// "Mark Done" with nothing selected, "Mark 3 Done" with three.
    private func label(_ verb: String, suffix: String = "") -> String {
        actions?.title(verb, suffix: suffix)
            ?? (suffix.isEmpty ? verb : "\(verb) \(suffix)")
    }

    private func scopeBinding(_ target: TriageScope) -> Binding<Bool> {
        Binding(
            get: { actions?.scope == target },
            set: { isOn in
                guard isOn else { return }
                actions?.selectScope(target)
            })
    }

    private func shortcut(for choice: ScopeShortcut) -> KeyboardShortcut? {
        guard let number = choice.shortcutNumber, (1...9).contains(number),
            let character = String(number).first
        else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: .command)
    }
}
