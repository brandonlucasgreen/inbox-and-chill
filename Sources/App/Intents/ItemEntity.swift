import AppIntents
import Foundation
import SwiftData

/// Shortcuts-facing value type mirroring one queue `Item`. Value semantics
/// keep it `Sendable` for the framework; the real `Item` model never leaves
/// the `MainActor`.
struct ItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Queue Item"
    static let defaultQuery = ItemEntityQuery()

    /// The `Item.uid`.
    var id: String
    var title: String
    var sourceKind: String
    var url: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(sourceKind)")
    }
}

extension ItemEntity {
    @MainActor init(_ item: Item) {
        self.id = item.uid
        self.title = item.title
        self.sourceKind = item.sourceKind
        self.url = item.urlString
    }
}

/// Looks up entities for Shortcuts' item picker, both by id (resolving a
/// previously-chosen item) and as suggestions (the current active queue).
struct ItemEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ItemEntity] {
        guard let appState = IntentContext.appState else { return [] }
        let descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { identifiers.contains($0.uid) })
        let items = (try? appState.container.mainContext.fetch(descriptor)) ?? []
        return items.map(ItemEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ItemEntity] {
        guard let appState = IntentContext.appState else { return [] }
        var descriptor = FetchDescriptor<Item>()
        descriptor.sortBy = [SortDescriptor(\.occurredAt, order: .reverse)]
        let items = (try? appState.container.mainContext.fetch(descriptor)) ?? []
        return items.filter(\.isActive).prefix(10).map(ItemEntity.init)
    }
}
