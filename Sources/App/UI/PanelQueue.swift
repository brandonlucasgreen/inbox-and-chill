import Foundation

/// Everything the panel draws, derived once.
///
/// The panel used to compute this as a dozen chained computed properties —
/// `queued` → `pinnedItems` / `activeItems` / `snoozedItems` → `activeGroups`
/// → `visibleUIDs`, plus `chipSources`, `chipCounts` and the filter's total.
/// Each one re-ran every time it was read, several of them re-read others,
/// and SwiftUI reads them many times per body pass. Worse, `index` was a
/// computed property read *inside* the row loop, so building the source
/// index — a full pass over every item — happened once per visible row.
///
/// None of that is visible at ten items and all of it is at a thousand.
/// Computing the whole layout once, as a value, makes the cost linear and
/// pays it exactly once per body pass.
///
/// Pure by construction: it takes plain arrays and returns plain arrays, so
/// the grouping and filter rules can be tested without a view or a store.
struct PanelQueue {
    let index: SourceIndex
    let pinned: [Item]
    let groups: [SourceGroup]
    let snoozed: [Item]
    /// Keyboard traversal order: exactly what is on screen, top to bottom.
    let visibleUIDs: [String]
    /// One chip per source with matching items, plus the active filter even
    /// if its source just emptied out, so the scope can't get stuck invisible.
    let chips: [SourceDisplay]
    let chipCounts: [String: Int]
    /// How many items the text filter matched, before the source scope.
    let matchCount: Int

    var isEmpty: Bool { pinned.isEmpty && groups.isEmpty && snoozed.isEmpty }

    /// - Parameter queued: every item still in the queue. The panel's query
    ///   already excludes done items, so this does not filter them again.
    init(
        queued: [Item], configs: [SourceConfig], sourceFilter: String?,
        filterText: String, showSnoozed: Bool
    ) {
        let index = SourceIndex(configs: configs, items: queued)
        self.index = index

        let matched = Self.textFiltered(queued, query: filterText, index: index)
        matchCount = matched.count
        var chipIDs = Set(matched.map(\.sourceID))
        if let sourceFilter { chipIDs.insert(sourceFilter) }
        chips = index.ordered(ids: chipIDs)
        chipCounts = matched.reduce(into: [:]) { counts, item in
            counts[item.sourceID, default: 0] += 1
        }

        let scoped =
            sourceFilter.map { filter in
                matched.filter { $0.sourceID == filter }
            } ?? matched
        pinned = scoped.filter(\.isPinned)
        snoozed = scoped.filter { $0.isSnoozed && !$0.isPinned }
        let active = scoped.filter { $0.isActive && !$0.isPinned }
        let grouped = Dictionary(grouping: active, by: \.sourceID)
        groups = index.ordered(ids: grouped.keys).compactMap { source in
            guard let items = grouped[source.id], !items.isEmpty else {
                return nil
            }
            return SourceGroup(source: source, items: items)
        }

        visibleUIDs =
            pinned.map(\.uid) + groups.flatMap { $0.items.map(\.uid) }
            + (showSnoozed ? snoozed.map(\.uid) : [])
    }

    /// Type-to-filter across title, snippet, person and source name.
    ///
    /// Lowercasing four strings per item is only paid while a query is
    /// actually being typed — an empty query returns the list untouched.
    static func textFiltered(
        _ list: [Item], query: String, index: SourceIndex
    ) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return list }
        return list.filter { item in
            [
                item.title, item.snippet ?? "", item.actorName ?? "",
                index.display(for: item).name,
            ]
            .contains { $0.lowercased().contains(query) }
        }
    }
}
