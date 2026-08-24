import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌥⌘I by default (decision §2.1.11), customizable in Settings.
    static let togglePanel = Self(
        "togglePanel", default: .init(.i, modifiers: [.command, .option]))
}
