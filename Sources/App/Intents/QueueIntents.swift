import AppIntents
import Foundation
import SwiftData

/// User-facing failures surfaced by Shortcuts (Settings > Shortcuts shows
/// `localizedStringResource` when one of these is thrown from `perform()`).
enum QueueIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotAvailable
    case itemNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotAvailable:
            return "Inbox & Chill isn’t ready yet — open the app and try again."
        case .itemNotFound:
            return "That item is no longer in your queue."
        }
    }
}

/// Fetches all items and applies the same active-queue rule the UI uses:
/// not done, not currently snoozed.
@MainActor
private func fetchActiveItems() throws -> [Item] {
    guard let appState = IntentContext.appState else { throw QueueIntentError.appNotAvailable }
    var descriptor = FetchDescriptor<Item>()
    descriptor.sortBy = [SortDescriptor(\.occurredAt, order: .reverse)]
    let all = try appState.container.mainContext.fetch(descriptor)
    return all.filter(\.isActive)
}

/// Builds the "N items: 3 Slack, 2 Linear…" dialog summary used by
/// `GetQueueIntent`, grouped by source kind, largest group first.
private func queueSummaryDialog(for items: [Item]) -> String {
    guard !items.isEmpty else { return "Your queue is empty." }
    let grouped = Dictionary(grouping: items, by: \.sourceKind)
    let parts = grouped
        .sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }
        .map { "\($0.value.count) \($0.key.capitalized)" }
    let shown = parts.prefix(4).joined(separator: ", ")
    let breakdown = parts.count > 4 ? "\(shown)…" : shown
    let noun = items.count == 1 ? "item" : "items"
    return "\(items.count) \(noun): \(breakdown)"
}

struct GetQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Get My Queue"
    static let description = IntentDescription(
        "Returns your active Inbox & Chill queue, optionally filtered by source or high-signal items.")

    @Parameter(title: "Source", description: "Filter by source kind, e.g. slack, linear, github.")
    var sourceKind: String?

    @Parameter(title: "High Signal Only", default: false)
    var highSignalOnly: Bool

    @Parameter(title: "Limit", default: 20)
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get my queue") {
            \.$sourceKind
            \.$highSignalOnly
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ItemEntity]> & ProvidesDialog {
        var active = try fetchActiveItems()
        if let sourceKind, !sourceKind.isEmpty {
            active = active.filter { $0.sourceKind.caseInsensitiveCompare(sourceKind) == .orderedSame }
        }
        if highSignalOnly {
            active = active.filter(\.highSignal)
        }
        let dialog = queueSummaryDialog(for: active)
        let limited = Array(active.prefix(max(0, limit)))
        return .result(value: limited.map(ItemEntity.init), dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct CountQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Count My Queue"
    static let description = IntentDescription(
        "Returns the number of active items in your Inbox & Chill queue. Useful in automations and widgets.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let active = try fetchActiveItems()
        let noun = active.count == 1 ? "item" : "items"
        return .result(value: active.count, dialog: "\(active.count) \(noun) in your queue.")
    }
}

struct SnoozeItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Snooze Item"
    static let description = IntentDescription("Snoozes a queue item until a given date.")

    @Parameter(title: "Item", description: "The item to snooze.")
    var item: ItemEntity

    @Parameter(title: "Until", description: "When the item should wake back up.")
    var until: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Snooze \(\.$item) until \(\.$until)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = IntentContext.appState else { throw QueueIntentError.appNotAvailable }
        let uid = item.id
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.uid == uid })
        guard let modelItem = try appState.container.mainContext.fetch(descriptor).first else {
            throw QueueIntentError.itemNotFound
        }
        appState.snooze(modelItem, until: until)
        return .result(dialog: "Snoozed “\(modelItem.title)”.")
    }
}

struct MarkItemDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Item Done"
    static let description = IntentDescription("Marks a queue item as done.")

    @Parameter(title: "Item", description: "The item to mark done.")
    var item: ItemEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$item) as done")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = IntentContext.appState else { throw QueueIntentError.appNotAvailable }
        let uid = item.id
        let descriptor = FetchDescriptor<Item>(predicate: #Predicate { $0.uid == uid })
        guard let modelItem = try appState.container.mainContext.fetch(descriptor).first else {
            throw QueueIntentError.itemNotFound
        }
        appState.markDone(modelItem)
        return .result(dialog: "Marked “\(modelItem.title)” done.")
    }
}
