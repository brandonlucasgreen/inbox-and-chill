import Foundation
import SwiftData
import Testing

@testable import InboxAndChill

// MARK: - Catch terms (Sources/App/Sync/TopicMatcher.swift)

/// The token rules, against the shapes measured in the live store on
/// 2026-08-26 (`docs/topic-grouping-plan.md` §1). The fixtures are real
/// title shapes, not invented ones — the false positive in
/// `bareIssueNumberIsNotATerm` is the one this suite exists for.
struct TopicMatcherTests {
    private func fields(
        _ title: String, _ snippet: String? = nil, _ url: String? = nil
    ) -> TopicMatcher.Fields {
        TopicMatcher.Fields(title: title, snippet: snippet, url: url)
    }

    @Test("An issue key is found in a title, a snippet or a URL")
    func findsIssueKeys() {
        #expect(
            TopicMatcher.tokens(
                in: fields("Checks failed: feat(core-api): route it / EPD-1873")
            ).contains("EPD-1873"))
        #expect(
            TopicMatcher.tokens(in: fields("Re: deploy", "about CORE-7130"))
                .contains("CORE-7130"))
    }

    @Test("A term never matches a longer key it happens to prefix")
    func wordBoundaryStopsPrefixMatches() {
        // Without the boundary check a topic for EPD-187 silently eats every
        // notification about EPD-1873, EPD-1874 and so on.
        #expect(!TopicMatcher.matches(["EPD-187"], fields("About EPD-1873")))
        #expect(TopicMatcher.matches(["EPD-187"], fields("About EPD-187 now")))
        #expect(TopicMatcher.matches(["EPD-187"], fields("(EPD-187)")))
    }

    @Test("Matching ignores case but the key pattern does not")
    func caseRules() {
        #expect(TopicMatcher.matches(["epd-1873"], fields("See EPD-1873")))
        // A lowercase slug is not an issue key, or every URL path would be.
        #expect(
            !TopicMatcher.tokens(in: fields("/blog/abc-123/"))
                .contains("abc-123"))
    }

    @Test("A bare #1234 is never a suggested term")
    func bareIssueNumberIsNotATerm() {
        // Measured: `#116` tied a test row to an unrelated Linear row on the
        // first pass over the real store. Only a repo-qualified form is safe.
        let items = [fields("Deploy #116 is out"), fields("Issue #116 filed")]
        #expect(TopicMatcher.suggestedTerms(for: items).isEmpty)

        let qualified = [
            fields("brandonlucasgreen/inbox-and-chill#116 merged"),
            fields("Review brandonlucasgreen/inbox-and-chill#116"),
        ]
        #expect(
            TopicMatcher.suggestedTerms(for: qualified)
                == ["brandonlucasgreen/inbox-and-chill#116"])
    }

    @Test("Only tokens shared by two or more items are suggested")
    func suggestionsNeedTwoItems() {
        let items = [
            fields("Checks failed: route feedback / EPD-1873"),
            fields("New comment on route feedback / EPD-1873"),
            fields("Something else entirely / CORE-9000"),
        ]
        #expect(TopicMatcher.suggestedTerms(for: items) == ["EPD-1873"])
        // One item on its own says nothing about what a group is about.
        #expect(TopicMatcher.suggestedTerms(for: [items[0]]).isEmpty)
    }

    @Test("A reminder contributes no term, which is the whole design")
    func remindersHaveNoIdentifier() {
        // 0 of 22 reminders in the live store carried an issue key. The
        // member that matters most is the one auto-catch can never find, so
        // an empty suggestion list has to be an ordinary outcome rather than
        // an error state.
        let items = [
            fields("Ship the feedback routing behind a flag", nil, "x-apple-reminderkit://1"),
            fields("Call the vet"),
        ]
        #expect(TopicMatcher.suggestedTerms(for: items).isEmpty)
    }

    @Test("A shared URL is a term; a bare host is not")
    func urlTerms() {
        let a = fields("Issue", nil, "https://linear.app/team/issue/ABC/x?utm=1")
        let b = fields("Chat", "see https://linear.app/team/issue/ABC/x")
        #expect(
            TopicMatcher.suggestedTerms(for: [a, b])
                .contains("https://linear.app/team/issue/ABC/x"))
        #expect(TopicMatcher.normalizedURL("https://github.com") == nil)
    }

    @Test("The suggested name drops the connector's event prefix")
    func namingIsModest() {
        let items = [
            fields("Checks failed: route feedback to FeatureOS / EPD-1873"),
            fields("Mentioned: route feedback to FeatureOS / EPD-1873"),
        ]
        let name = TopicMatcher.suggestedName(for: items)
        #expect(name.hasPrefix("EPD-1873"))
        #expect(!name.contains("Checks failed"))
        #expect(!name.contains("Mentioned"))
        // "feat(core-api): …" keeps its colon — that is part of the title,
        // not a label on it.
        #expect(
            TopicMatcher.strippedEventPrefix("feat(core-api): route it")
                == "feat(core-api): route it")
    }

    @Test("Terms are matched, not interpreted as patterns")
    func termsAreLiteral() {
        // A user-typed term containing regex metacharacters must not become
        // a pattern — it either matches literally or it doesn't.
        #expect(TopicMatcher.matches(["feat(core-api)"], fields("in feat(core-api) today")))
        #expect(!TopicMatcher.matches(["a.c"], fields("abc")))
    }
}

// MARK: - Topics in the panel layout (Sources/App/UI/PanelQueue.swift)

/// Where a topic lands, what dissolves it, and what the keyboard walks.
struct PanelTopicLayoutTests {
    private let configs = [
        SourceConfig(id: "a", kind: "test", displayName: "Alpha", sortOrder: 0),
        SourceConfig(id: "b", kind: "test", displayName: "Beta", sortOrder: 1),
    ]

    private func item(
        _ uid: String, source: String = "a", title: String = "T",
        topic: String? = nil, minutesAgo: Int = 0, pinned: Bool = false,
        snoozedForHours: Int? = nil, seen: Bool = true
    ) -> Item {
        let item = Item(
            uid: uid, sourceID: source, sourceKind: "test", kind: "mention",
            title: title,
            occurredAt: Date(timeIntervalSinceNow: TimeInterval(-60 * minutesAgo)))
        item.topicID = topic
        if pinned { item.pinnedAt = .now }
        if seen { item.seenAt = .now }
        if let hours = snoozedForHours {
            item.snoozedUntil = Date(
                timeIntervalSinceNow: TimeInterval(3600 * hours))
        }
        return item
    }

    private func layout(
        _ items: [Item], topics: [Topic] = [Topic(id: "t", name: "Topic")],
        filter: String? = nil, text: String = "", showSnoozed: Bool = false,
        open: String? = nil
    ) -> PanelQueue {
        PanelQueue(
            queued: items, configs: configs, allTopics: topics,
            sourceFilter: filter, filterText: text, showSnoozed: showSnoozed,
            openTopicID: open)
    }

    @Test("A grouped item is never rendered outside its topic")
    func membersLeaveTheirSourceSections() {
        let queue = layout([
            item("1", topic: "t"), item("2", source: "b", topic: "t"),
            item("3"),
        ])
        #expect(queue.topics.map(\.id) == ["t"])
        #expect(queue.topics[0].members.map(\.uid).sorted() == ["1", "2"])
        #expect(queue.groups.flatMap { $0.items.map(\.uid) } == ["3"])
    }

    @Test("One member is not a topic — it goes back to being a row")
    func aSingleMemberDegrades() {
        // `.remoteTruth` erodes topics to one member routinely, and a
        // disclosure triangle over one thing is a lie.
        let queue = layout([item("1", topic: "t"), item("2")])
        #expect(queue.topics.isEmpty)
        #expect(queue.groups.flatMap { $0.items.map(\.uid) }.sorted() == ["1", "2"])
        // …but the row still says it belongs to something.
        #expect(queue.topicOf["1"] == "t")
    }

    @Test("A source filter dissolves topics")
    func sourceScopeDissolves() {
        let items = [item("1", topic: "t"), item("2", source: "b", topic: "t")]
        #expect(layout(items).topics.count == 1)
        let scoped = layout(items, filter: "a")
        #expect(scoped.topics.isEmpty)
        #expect(scoped.groups.flatMap { $0.items.map(\.uid) } == ["1"])
    }

    @Test("A topic is placed by its members: pinned, snoozed, or neither")
    func placementFollowsMembers() {
        let pinnedTopic = layout([
            item("1", topic: "t", pinned: true),
            item("2", topic: "t", pinned: true),
        ])
        #expect(pinnedTopic.pinnedTopics.map(\.id) == ["t"])
        #expect(pinnedTopic.topics.isEmpty)
        #expect(pinnedTopic.pinned.isEmpty)

        let snoozedTopic = layout(
            [
                item("1", topic: "t", snoozedForHours: 3),
                item("2", topic: "t", snoozedForHours: 3),
            ], showSnoozed: true)
        #expect(snoozedTopic.snoozedTopics.map(\.id) == ["t"])
        #expect(snoozedTopic.topics.isEmpty)

        // One member still awake keeps the whole thing in Topics.
        let mixed = layout([
            item("1", topic: "t"), item("2", topic: "t", snoozedForHours: 3),
        ])
        #expect(mixed.topics.map(\.id) == ["t"])
        #expect(mixed.topics[0].activeCount == 1)
        #expect(mixed.topics[0].members.count == 2)
    }

    @Test("The keyboard walks into an open topic and past a closed one")
    func traversalIncludesOpenMembers() {
        let items = [
            item("1", topic: "t", minutesAgo: 1),
            item("2", topic: "t", minutesAgo: 2),
            item("3", minutesAgo: 3),
        ]
        #expect(layout(items).visibleUIDs == ["topic:t", "3"])
        #expect(
            layout(items, open: "t").visibleUIDs
                == ["topic:t", "1", "2", "3"])
    }

    @Test("Typing the topic's name keeps its members")
    func textFilterMatchesTheTopicName() {
        let topics = [Topic(id: "t", name: "EPD-1873 — routing")]
        let items = [
            item("1", title: "Checks failed", topic: "t"),
            item("2", title: "New comment", topic: "t"),
            item("3", title: "Unrelated"),
        ]
        let queue = layout(items, topics: topics, text: "EPD-1873")
        #expect(queue.topics.map(\.id) == ["t"])
        #expect(queue.topics[0].members.count == 2)
        #expect(queue.groups.isEmpty)
    }

    @Test("A topic id is never mistaken for an item uid")
    func rowIDNamespace() {
        #expect(QueueRowID.topic("abc") == "topic:abc")
        #expect(QueueRowID.topicID(from: "topic:abc") == "abc")
        #expect(QueueRowID.topicID(from: "slack:C123.456") == nil)
    }

    @Test("A topic is unseen while any member is, and high-signal likewise")
    func aggregateState() {
        let queue = layout([
            item("1", topic: "t", seen: false), item("2", topic: "t"),
        ])
        #expect(queue.topics[0].isSeen == false)
    }
}

// MARK: - Auto-grouping folds (Sources/App/UI/PanelQueue.swift)

/// A fold is `TopicGroup.fold`: one source's rows sharing a `groupKey`,
/// computed by the layout and never stored. These pin down where it lands
/// (inside its source section), what dissolves it (nothing a topic's rules
/// would — a source filter *keeps* it), and the one invariant: a row filed
/// in a topic by hand is never folded.
struct PanelFoldLayoutTests {
    private let configs = [
        SourceConfig(id: "a", kind: "test", displayName: "Alpha", sortOrder: 0),
        SourceConfig(id: "b", kind: "test", displayName: "Beta", sortOrder: 1),
    ]

    private func item(
        _ uid: String, source: String = "a", title: String = "T",
        key: String? = nil, label: String? = nil, topic: String? = nil,
        minutesAgo: Int = 0, pinned: Bool = false
    ) -> Item {
        let item = Item(
            uid: uid, sourceID: source, sourceKind: "test", kind: "mention",
            title: title,
            occurredAt: Date(timeIntervalSinceNow: TimeInterval(-60 * minutesAgo)),
            groupKey: key, groupLabel: label ?? key.map { "#\($0)" })
        item.topicID = topic
        if pinned { item.pinnedAt = .now }
        item.seenAt = .now
        return item
    }

    private func layout(
        _ items: [Item], grouping: Set<String> = ["a", "b"],
        filter: String? = nil, text: String = "", open: String? = nil
    ) -> PanelQueue {
        PanelQueue(
            queued: items, configs: configs,
            allTopics: [Topic(id: "t", name: "Topic")],
            sourceFilter: filter, filterText: text, showSnoozed: false,
            openTopicID: open, groupingSourceIDs: grouping)
    }

    private func fold(_ queue: PanelQueue, source: String = "a") -> [TopicGroup] {
        queue.groups.first { $0.id == source }?.folds ?? []
    }

    @Test("Rows sharing a key fold inside their source section, nowhere else")
    func foldsLandInsideTheirSection() {
        let queue = layout([
            item("1", key: "c1", minutesAgo: 1), item("2", key: "c1", minutesAgo: 2),
            item("3", key: "c2", minutesAgo: 3), item("4", source: "b", key: "c1"),
        ])
        #expect(queue.topics.isEmpty)
        let folds = fold(queue)
        #expect(folds.map(\.id) == [TopicGroup.foldID(sourceID: "a", key: "c1")])
        #expect(folds[0].isFold)
        #expect(folds[0].name == "#c1")
        #expect(folds[0].members.map(\.uid) == ["1", "2"])
        // Loose: the single-key row here, and Beta's lone row — a key is
        // per source, so Beta's "c1" never joins Alpha's.
        #expect(queue.groups[0].items.map(\.uid) == ["3"])
        #expect(queue.groups[1].items.map(\.uid) == ["4"])
        #expect(fold(queue, source: "b").isEmpty)
    }

    @Test("Folds and loose rows share one list, newest first")
    func sectionOrderIsByDate() {
        let queue = layout([
            item("old-fold-1", key: "c1", minutesAgo: 30),
            item("old-fold-2", key: "c1", minutesAgo: 40),
            item("loose-new", minutesAgo: 5),
            item("loose-old", minutesAgo: 60),
        ])
        #expect(
            queue.groups[0].rows.map(\.id) == [
                "loose-new", QueueRowID.topic(TopicGroup.foldID(sourceID: "a", key: "c1")),
                "loose-old",
            ])
        #expect(queue.groups[0].rowCount == 3)
        #expect(queue.visibleUIDs == queue.groups[0].rows.map(\.id))
    }

    @Test("A source filter keeps folds — a same-source fold answers 'show me Slack'")
    func sourceScopeKeepsFolds() {
        let items = [item("1", key: "c1"), item("2", key: "c1"), item("3", source: "b")]
        #expect(fold(layout(items, filter: "a")).count == 1)
        #expect(layout(items, filter: "a").groups.count == 1)
    }

    @Test("One row with a key is a row, with no chip")
    func aSingleRowStaysLoose() {
        let queue = layout([item("1", key: "c1"), item("2", key: "c2")])
        #expect(fold(queue).isEmpty)
        #expect(queue.groups[0].items.map(\.uid) == ["1", "2"])
        #expect(queue.topicOf.isEmpty)
    }

    @Test("Explicit beats rule: a row filed in a topic is never folded")
    func topicMembershipWins() {
        let queue = layout([
            item("1", key: "c1", topic: "t"), item("2", key: "c1", topic: "t"),
            item("3", key: "c1", minutesAgo: 1), item("4", key: "c1", minutesAgo: 2),
        ])
        #expect(queue.topics.map(\.id) == ["t"])
        #expect(fold(queue)[0].members.map(\.uid) == ["3", "4"])
    }

    @Test("Grouping off gives back the loose rows in queue order")
    func toggleOffIsLossless() {
        let items = [
            item("1", key: "c1", minutesAgo: 1), item("2", key: "c1", minutesAgo: 2),
            item("3", minutesAgo: 3),
        ]
        let off = layout(items, grouping: [])
        #expect(off.groups[0].folds.isEmpty)
        #expect(off.groups[0].items.map(\.uid) == ["1", "2", "3"])
        #expect(off.visibleUIDs == ["1", "2", "3"])
    }

    @Test("An open fold splices its members into the traversal order")
    func openFoldSplicesMembers() {
        let id = TopicGroup.foldID(sourceID: "a", key: "c1")
        let queue = layout(
            [item("1", key: "c1", minutesAgo: 1), item("2", key: "c1", minutesAgo: 2), item("3", minutesAgo: 9)],
            open: id)
        #expect(queue.visibleUIDs == [QueueRowID.topic(id), "1", "2", "3"])
        #expect(queue.topic(rowID: QueueRowID.topic(id))?.id == id)
    }

    @Test("The header reads by the newest member's label, and previews its title")
    func headerFollowsTheNewestMember() {
        let queue = layout([
            item("1", title: "Latest", key: "c1", label: "#renamed", minutesAgo: 1),
            item("2", title: "Older", key: "c1", label: "#old-name", minutesAgo: 5),
        ])
        #expect(fold(queue)[0].name == "#renamed")
        #expect(fold(queue)[0].preview == "Latest")
    }

    @Test("Typing a fold's label finds its members")
    func textFilterMatchesTheLabel() {
        let queue = layout(
            [item("1", title: "x", key: "c1", label: "#deploys"), item("2", title: "y", key: "c1", label: "#deploys")],
            text: "deploys")
        #expect(queue.matchCount == 2)
        #expect(fold(queue).count == 1)
    }

    @Test("Pinned rows stay loose in Pinned rather than folding")
    func pinnedRowsAreNotFolded() {
        let queue = layout([
            item("1", key: "c1", pinned: true), item("2", key: "c1", pinned: true),
        ])
        #expect(queue.pinned.map(\.uid).sorted() == ["1", "2"])
        #expect(queue.groups.isEmpty)
    }

    @Test("A fold id round-trips through its parts, colons in the key included")
    func foldIDParts() throws {
        let id = TopicGroup.foldID(sourceID: "src", key: "issue:EPD-1873")
        let parts = try #require(TopicGroup.foldParts(id))
        #expect(parts.sourceID == "src")
        #expect(parts.key == "issue:EPD-1873")
        #expect(TopicGroup.foldParts("topic:abc") == nil)
        #expect(TopicGroup.foldParts("fold:nokey") == nil)
    }
}

// MARK: - Topics in the store (Sources/App/Sync/Store.swift)

@MainActor
struct TopicStoreTests {
    private func makeStore() throws -> Store {
        let container = try ModelContainer(
            for: Item.self, SourceConfig.self, Topic.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return Store(modelContainer: container)
    }

    private func remote(
        _ id: String, title: String, at: Date = .now, group: String? = nil,
        loud: Bool = false
    ) -> RemoteItem {
        RemoteItem(
            externalID: id, kind: "mention", title: title, occurredAt: at,
            highSignal: loud, groupKey: group, groupLabel: group)
    }

    private func seed(_ store: Store, _ remotes: [RemoteItem]) async throws {
        _ = try await store.reconcile(
            snapshot: remotes, sourceID: "s", sourceKind: "test",
            remoteTruth: false)
    }

    @Test("A poll does not dissolve a topic")
    func updateLeavesMembershipAlone() async throws {
        // `Store.update(_:from:)` refreshes nearly every field from the
        // remote — `kind` was added to it deliberately — so a field that has
        // to survive a poll must be left out of it by hand. This is the
        // regression that would otherwise erase the feature overnight.
        let store = try makeStore()
        try await seed(store, [remote("a", title: "One")])
        let id = try await store.createTopic(
            name: "T", terms: [], memberUIDs: ["test:a"])

        try await seed(store, [remote("a", title: "One, edited")])
        #expect(try await store.topicMembership()["test:a"] == id)
    }

    @Test("A poll DOES refresh the group key — the source owns it")
    func updateRefreshesGroupKey() async throws {
        // The inverse of `updateLeavesMembershipAlone`, on purpose: a fold
        // is the source's fact about an item, so a renamed channel or a
        // re-filed message has to follow the source on the next poll.
        let store = try makeStore()
        try await seed(store, [
            remote("a", title: "One", group: "c1"), remote("b", title: "Two", group: "c1"),
        ])
        var counts = try await store.badgeCounts(
            countedSourceIDs: ["s"], groupingSourceIDs: ["s"])
        #expect(counts.total == 1)
        try await seed(store, [
            remote("a", title: "One", group: "c1"), remote("b", title: "Two", group: nil),
        ])
        counts = try await store.badgeCounts(
            countedSourceIDs: ["s"], groupingSourceIDs: ["s"])
        #expect(counts.total == 2)
    }

    @Test("The badge counts a fold as one, and a fold is loud if any member is")
    func badgeCountsAFoldAsOne() async throws {
        let store = try makeStore()
        try await seed(store, [
            remote("a", title: "One", group: "c1"),
            remote("b", title: "Two", group: "c1", loud: true),
            remote("c", title: "Three", group: "c2"),
            remote("d", title: "Four"),
        ])
        let folded = try await store.badgeCounts(
            countedSourceIDs: ["s"], groupingSourceIDs: ["s"])
        #expect(folded.total == 3)  // c1 fold, c2 alone, d
        #expect(folded.highSignal == 1)
        // Grouping off for the source: every row counts.
        let flat = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(flat.total == 4)
        #expect(flat.highSignal == 1)
    }

    @Test("Terms back-fill when the topic is made")
    func creatingATopicGathersWhatIsAlreadyThere() async throws {
        // Making a topic for EPD-1873 should collect the rows that already
        // mention it, not only the ones that happened to be marked.
        let store = try makeStore()
        try await seed(store, [
            remote("a", title: "Checks failed / EPD-1873"),
            remote("b", title: "New comment / EPD-1873"),
            remote("c", title: "Something else"),
        ])
        let id = try await store.createTopic(
            name: "EPD-1873", terms: ["EPD-1873"], memberUIDs: [])
        let membership = try await store.topicMembership()
        #expect(membership["test:a"] == id)
        #expect(membership["test:b"] == id)
        #expect(membership["test:c"] == nil)
    }

    @Test("A newly arriving item joins a matching topic")
    func autoCatchOnInsert() async throws {
        let store = try makeStore()
        let id = try await store.createTopic(name: "T", terms: ["EPD-1873"])
        try await seed(store, [remote("a", title: "Mentioned / EPD-1873")])
        #expect(try await store.topicMembership()["test:a"] == id)
    }

    @Test("An explicit member beats a rule, in both directions")
    func explicitMembershipWins() async throws {
        let store = try makeStore()
        try await seed(store, [remote("a", title: "Mentioned / EPD-1873")])
        let catcher = try await store.createTopic(
            name: "Catcher", terms: ["EPD-1873"])
        #expect(try await store.topicMembership()["test:a"] == catcher)

        // A second topic's back-fill must not steal a row that is already
        // filed somewhere.
        _ = try await store.createTopic(name: "Thief", terms: ["EPD-1873"])
        #expect(try await store.topicMembership()["test:a"] == catcher)

        // And taking a row out by hand has to stick across the next poll,
        // which is why matching runs on insert only.
        try await store.removeFromTopic(uids: ["test:a"])
        try await seed(store, [remote("a", title: "Mentioned / EPD-1873")])
        #expect(try await store.topicMembership()["test:a"] == nil)
    }

    @Test("Ungrouping dismisses nothing")
    func deletingATopicKeepsItsMembers() async throws {
        let store = try makeStore()
        try await seed(store, [remote("a", title: "One"), remote("b", title: "Two")])
        let id = try await store.createTopic(
            name: "T", memberUIDs: ["test:a", "test:b"])
        try await store.deleteTopic(id: id)
        #expect(try await store.topicMembership().isEmpty)
        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 2)
    }

    @Test("The badge counts a topic as one")
    func topicCountsOnce() async throws {
        let store = try makeStore()
        try await seed(store, [
            remote("a", title: "One"), remote("b", title: "Two"),
            remote("c", title: "Three"),
        ])
        #expect(
            try await store.badgeCounts(countedSourceIDs: ["s"]).total == 3)
        _ = try await store.createTopic(
            name: "T", memberUIDs: ["test:a", "test:b"])
        // Two grouped plus one loose reads as two things waiting.
        #expect(
            try await store.badgeCounts(countedSourceIDs: ["s"]).total == 2)
    }

    @Test("A batch done is one write and one undo, honouring each reason")
    func batchDoneAndUndo() async throws {
        let store = try makeStore()
        try await seed(store, [remote("a", title: "One"), remote("b", title: "Two")])
        try await store.markDone(uids: ["test:a"], reason: Store.DoneReason.completed)
        try await store.markDone(uids: ["test:b"])

        let reasons = try await store.undoDone(uids: ["test:a", "test:b"])
        #expect(reasons["test:a"] == Store.DoneReason.completed)
        #expect(reasons["test:b"] == Store.DoneReason.user)
        #expect(
            try await store.badgeCounts(countedSourceIDs: ["s"]).total == 2)
    }

    @Test("Pinning a batch normalizes rather than flipping each row")
    func batchPinNormalizes() async throws {
        let store = try makeStore()
        try await seed(store, [remote("a", title: "One"), remote("b", title: "Two")])
        try await store.setPinned(uids: ["test:a"], pinned: true)
        try await store.setPinned(uids: ["test:a", "test:b"], pinned: true)
        // Both pinned — a flip-each would have unpinned `a` back off again.
        let queue = try await store.topicMembership()  // forces a fetch
        _ = queue
        try await store.setPinned(uids: ["test:a", "test:b"], pinned: false)
        #expect(
            try await store.badgeCounts(countedSourceIDs: ["s"]).total == 2)
    }

    @Test("Marking a batch read normalizes, and unread sticks")
    func batchSeenNormalizes() async throws {
        let store = try makeStore()
        try await seed(store, [
            remote("a", title: "One"), remote("b", title: "Two"),
        ])
        try await store.markSeen(uid: "test:a")

        // Mixed → all read. A flip-each would have unread `a` again.
        try await store.setSeen(uids: ["test:a", "test:b"], seen: true)
        #expect(try await store.seenAt(uid: "test:a") != nil)
        #expect(try await store.seenAt(uid: "test:b") != nil)

        // All read → all unread, and the hold is what makes it survive the
        // next time the selection lands on the row.
        try await store.setSeen(uids: ["test:a", "test:b"], seen: false)
        #expect(try await store.seenAt(uid: "test:a") == nil)
        #expect(try await store.markSeen(uid: "test:a") == false)
    }

    @Test("An empty topic survives; an old empty one is purged")
    func purgeRules() async throws {
        // A topic outliving its members is the resting state that lets
        // tomorrow's matching item re-form it, so emptiness alone must not
        // delete one.
        let store = try makeStore()
        let fresh = try await store.createTopic(name: "Fresh", terms: ["X-1"])
        _ = try await store.purge()
        try await seed(store, [remote("a", title: "About X-1")])
        #expect(try await store.topicMembership()["test:a"] == fresh)
    }
}
