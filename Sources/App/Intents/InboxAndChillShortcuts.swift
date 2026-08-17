import AppIntents

/// Registers the app's built-in Shortcuts phrases. Discovered automatically
/// by the system at launch — nothing else needs to reference this type.
struct InboxAndChillShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetQueueIntent(),
            phrases: [
                "Get my queue in \(.applicationName)",
                "Show my queue in \(.applicationName)",
            ],
            shortTitle: "Get My Queue",
            systemImageName: "tray.full"
        )
        AppShortcut(
            intent: CountQueueIntent(),
            phrases: [
                "How many items in \(.applicationName)",
                "Count my queue in \(.applicationName)",
            ],
            shortTitle: "Count My Queue",
            systemImageName: "number"
        )
        AppShortcut(
            intent: SnoozeItemIntent(),
            phrases: [
                "Snooze an item in \(.applicationName)"
            ],
            shortTitle: "Snooze Item",
            systemImageName: "zzz"
        )
        AppShortcut(
            intent: MarkItemDoneIntent(),
            phrases: [
                "Mark an item done in \(.applicationName)"
            ],
            shortTitle: "Mark Item Done",
            systemImageName: "checkmark"
        )
    }
}
