import Foundation

/// A row in the panel's keyboard order is either an item or a topic header,
/// and the selection is one string. Topic ids are UUIDs and item uids are
/// `"<kind>:<external>"`, so they could not collide in practice — but
/// "could not collide in practice" is how the `#1234` false match happened,
/// so the namespace is made explicit instead.
enum QueueRowID {
    static func topic(_ id: String) -> String { "topic:\(id)" }

    static func topicID(from rowID: String) -> String? {
        rowID.hasPrefix("topic:") ? String(rowID.dropFirst(6)) : nil
    }
}

/// One rendered topic: the header row plus everything filed under it.
struct TopicGroup: Identifiable {
    var id: String
    var name: String
    /// Every member still in the queue, newest first — including snoozed
    /// ones, which are only ever visible once the topic is expanded and
    /// which carry their own wake time on the row.
    let members: [Item]
    /// The sources represented, in the order the source chips use.
    let sources: [SourceDisplay]

    var rowID: String { QueueRowID.topic(id) }
    /// What the header counts. Snoozed members are in the queue but not
    /// waiting on you, so they are not part of "how many is this".
    var activeCount: Int { members.filter(\.isActive).count }
    var isPinned: Bool { !members.isEmpty && members.allSatisfy(\.isPinned) }
    var isSnoozed: Bool { !members.isEmpty && !members.contains(where: \.isActive) }
    var highSignal: Bool { members.contains { $0.isActive && $0.highSignal } }
    var isSeen: Bool { members.allSatisfy(\.isSeen) }
    var newest: Date { members.map(\.occurredAt).max() ?? .distantPast }
    var memberUIDs: [String] { members.map(\.uid) }
}

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
///
/// ## Where a topic lands
///
/// **A grouped item is never rendered outside its topic** — one row per
/// thing, everywhere, which is the whole point. The topic itself is placed
/// by its members: all pinned puts it in Pinned, all snoozed puts it in
/// Snoozed, anything else puts it in Topics between the two. So pinning a
/// topic moves the topic rather than scattering four rows into Pinned.
///
/// Two things dissolve a topic back into ordinary rows:
///
/// - **A source filter.** Scoping to Slack means "show me Slack", so the
///   Slack member appears as a plain row under SLACK.
/// - **Falling below `TopicPolicy.minimumVisibleMembers`.** A disclosure
///   triangle over one item is a lie, and remote-truth archiving erodes
///   topics to one member routinely.
struct PanelQueue {
    let index: SourceIndex
    let pinned: [Item]
    let pinnedTopics: [TopicGroup]
    let topics: [TopicGroup]
    let groups: [SourceGroup]
    let snoozed: [Item]
    let snoozedTopics: [TopicGroup]
    /// Keyboard traversal order: exactly what is on screen, top to bottom.
    let visibleUIDs: [String]
    /// One chip per source with matching items, plus the active filter even
    /// if its source just emptied out, so the scope can't get stuck invisible.
    let chips: [SourceDisplay]
    let chipCounts: [String: Int]
    /// How many items the text filter matched, before the source scope.
    let matchCount: Int
    /// uid → topic id, for every item that has one and is on screen. Rows use
    /// it to draw the topic chip on a member that is showing as a plain row.
    let topicOf: [String: String]

    var isEmpty: Bool {
        pinned.isEmpty && pinnedTopics.isEmpty && topics.isEmpty
            && groups.isEmpty && snoozed.isEmpty && snoozedTopics.isEmpty
    }

    /// - Parameters:
    ///   - queued: every item still in the queue. The panel's query already
    ///     excludes done items, so this does not filter them again.
    ///   - openTopicID: which topic is showing its members. Part of the
    ///     layout rather than of the view, because it changes the keyboard
    ///     traversal order — arrowing down has to walk into an open topic.
    init(
        queued: [Item], configs: [SourceConfig], allTopics: [Topic] = [],
        sourceFilter: String?, filterText: String, showSnoozed: Bool,
        openTopicID: String? = nil
    ) {
        let index = SourceIndex(configs: configs, items: queued)
        self.index = index

        let topicsByID = Dictionary(
            allTopics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matched = Self.textFiltered(
            queued, query: filterText, index: index, topics: topicsByID)
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

        // A source filter dissolves topics: the user asked for one source,
        // and a cross-source row is not an answer to that question.
        let grouping = sourceFilter == nil
        var membersByTopic: [String: [Item]] = [:]
        if grouping {
            for item in scoped {
                guard let id = item.topicID, topicsByID[id] != nil else {
                    continue
                }
                membersByTopic[id, default: []].append(item)
            }
            // Below the threshold a topic is not a topic; its member goes
            // back to being an ordinary row.
            membersByTopic = membersByTopic.filter {
                $0.value.count >= TopicPolicy.minimumVisibleMembers
            }
        }
        let groupedUIDs = Set(membersByTopic.values.flatMap { $0 }.map(\.uid))

        var built: [TopicGroup] = []
        for (id, members) in membersByTopic {
            guard let topic = topicsByID[id] else { continue }
            let sorted = members.sorted { $0.occurredAt > $1.occurredAt }
            built.append(
                TopicGroup(
                    id: id, name: topic.name, members: sorted,
                    sources: index.ordered(ids: Set(sorted.map(\.sourceID)))))
        }
        built.sort { $0.newest > $1.newest }

        pinnedTopics = built.filter(\.isPinned)
        snoozedTopics = built.filter { !$0.isPinned && $0.isSnoozed }
        topics = built.filter { !$0.isPinned && !$0.isSnoozed }

        let loose = scoped.filter { !groupedUIDs.contains($0.uid) }
        pinned = loose.filter(\.isPinned)
        snoozed = loose.filter { $0.isSnoozed && !$0.isPinned }
        let active = loose.filter { $0.isActive && !$0.isPinned }
        let bySource = Dictionary(grouping: active, by: \.sourceID)
        groups = index.ordered(ids: bySource.keys).compactMap { source in
            guard let items = bySource[source.id], !items.isEmpty else {
                return nil
            }
            return SourceGroup(source: source, items: items)
        }

        topicOf = scoped.reduce(into: [:]) { map, item in
            if let id = item.topicID, topicsByID[id] != nil {
                map[item.uid] = id
            }
        }

        func rows(_ list: [TopicGroup]) -> [String] {
            list.flatMap { topic -> [String] in
                topic.id == openTopicID
                    ? [topic.rowID] + topic.memberUIDs : [topic.rowID]
            }
        }
        visibleUIDs =
            pinned.map(\.uid) + rows(pinnedTopics) + rows(topics)
            + groups.flatMap { $0.items.map(\.uid) }
            + (showSnoozed ? snoozed.map(\.uid) + rows(snoozedTopics) : [])
    }

    /// Every topic on screen, wherever it was placed. Used to answer "is this
    /// row id a topic, and which one" without three lookups.
    func topic(rowID: String) -> TopicGroup? {
        guard let id = QueueRowID.topicID(from: rowID) else { return nil }
        return (pinnedTopics + topics + snoozedTopics).first { $0.id == id }
    }

    /// Type-to-filter across title, snippet, person, source name — and the
    /// name of the topic an item belongs to, so typing "EPD-1873" lands on
    /// the topic rather than on whichever rows happen to spell it out.
    ///
    /// Lowercasing four strings per item is only paid while a query is
    /// actually being typed — an empty query returns the list untouched.
    static func textFiltered(
        _ list: [Item], query: String, index: SourceIndex,
        topics: [String: Topic] = [:]
    ) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return list }
        return list.filter { item in
            [
                item.title, item.snippet ?? "", item.actorName ?? "",
                index.display(for: item).name,
                item.topicID.flatMap { topics[$0]?.name } ?? "",
            ]
            .contains { $0.lowercased().contains(query) }
        }
    }
}
