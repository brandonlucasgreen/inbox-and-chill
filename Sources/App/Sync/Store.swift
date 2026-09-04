import Foundation
import SwiftData

/// Lightweight value snapshot of an Item, safe to pass across actors.
struct ItemSummary: Sendable, Identifiable {
    var id: String  // uid
    var sourceID: String
    var sourceKind: String
    var title: String
    var snippet: String?
    var urlString: String?
    var highSignal: Bool
}

struct ReconcileResult: Sendable {
    var inserted: [ItemSummary] = []
    var clearedRemotely: Int = 0
}

/// All mutations to the item store go through this actor.
@ModelActor
actor Store {
    // MARK: Reconciliation

    /// Merge a full connector snapshot. New uids insert; known uids update
    /// fields; uids missing from the snapshot auto-archive iff `remoteTruth`
    /// (hybrid rule) — unless pinned (pins are immortal, decision §2.1.6).
    func reconcile(
        snapshot: [RemoteItem], sourceID: String, sourceKind: String,
        remoteTruth: Bool, announcesReturn: Bool = false
    ) throws -> ReconcileResult {
        var result = ReconcileResult()
        let existing = try items(sourceID: sourceID)
        let rules = try topicRules()
        var seen = Set<String>()

        for remote in snapshot {
            let uid = remote.uid(sourceKind: sourceKind)
            seen.insert(uid)
            if let item = existing.first(where: { $0.uid == uid }) {
                let revived = resurrectIfNeeded(item, from: remote)
                update(item, from: remote)
                if revived, announcesReturn { result.inserted.append(summary(item)) }
            } else {
                let item = Item(
                    uid: uid, sourceID: sourceID, sourceKind: sourceKind,
                    kind: remote.kind, title: remote.title,
                    snippet: remote.snippet, urlString: remote.url,
                    actorName: remote.actorName, occurredAt: remote.occurredAt,
                    highSignal: remote.highSignal, payload: remote.payload,
                    groupKey: remote.groupKey, groupLabel: remote.groupLabel)
                item.topicID = Self.topicID(matching: remote, in: rules)
                modelContext.insert(item)
                result.inserted.append(summary(item))
            }
        }

        if remoteTruth {
            for item in existing
            where !seen.contains(item.uid) && item.doneAt == nil
                && !item.isPinned {
                item.doneAt = .now
                item.doneReason = DoneReason.remote
                item.updatedAt = .now
                result.clearedRemotely += 1
            }
        }
        try modelContext.save()
        return result
    }

    /// Apply an incremental push event.
    func apply(
        event: ConnectorEvent, sourceID: String, sourceKind: String,
        remoteTruth: Bool, announcesReturn: Bool = false
    ) throws -> ReconcileResult {
        switch event {
        case .snapshot(let items):
            return try reconcile(
                snapshot: items, sourceID: sourceID, sourceKind: sourceKind,
                remoteTruth: remoteTruth, announcesReturn: announcesReturn)
        case .upsert(let remotes):
            var result = ReconcileResult()
            let existing = try items(sourceID: sourceID)
            let rules = try topicRules()
            for remote in remotes {
                let uid = remote.uid(sourceKind: sourceKind)
                if let item = existing.first(where: { $0.uid == uid }) {
                    let revived = resurrectIfNeeded(item, from: remote)
                    update(item, from: remote)
                    if revived, announcesReturn { result.inserted.append(summary(item)) }
                } else {
                    let item = Item(
                        uid: uid, sourceID: sourceID, sourceKind: sourceKind,
                        kind: remote.kind, title: remote.title,
                        snippet: remote.snippet, urlString: remote.url,
                        actorName: remote.actorName,
                        occurredAt: remote.occurredAt,
                        highSignal: remote.highSignal, payload: remote.payload,
                        groupKey: remote.groupKey, groupLabel: remote.groupLabel)
                    item.topicID = Self.topicID(matching: remote, in: rules)
                    modelContext.insert(item)
                    result.inserted.append(summary(item))
                }
            }
            try modelContext.save()
            return result
        case .clear(let externalIDs):
            var result = ReconcileResult()
            let uids = Set(externalIDs.map { "\(sourceKind):\($0)" })
            for item in try items(sourceID: sourceID)
            where uids.contains(item.uid) && item.doneAt == nil
                && !item.isPinned {
                item.doneAt = .now
                item.doneReason = DoneReason.remote
                item.updatedAt = .now
                result.clearedRemotely += 1
            }
            try modelContext.save()
            return result
        case .status:
            return ReconcileResult()
        }
    }

    // MARK: Triage verbs

    /// Reasons an item can be done. `doneReason` was already a bare string on
    /// `Item`; naming the values keeps the archive's wording and
    /// `resurrectIfNeeded`'s rule reading off the same list.
    enum DoneReason {
        /// Dismissed by the user — struck from the queue, nothing written to
        /// the source.
        static let user = "user"
        /// The source cleared it: absent from a `.remoteTruth` snapshot.
        static let remote = "remote"
        /// Finished for real in the source, by `C` on a to-do row. Behaves
        /// exactly like `user` in `resurrectIfNeeded` — only a moved
        /// `occurredAt` brings it back — but the archive can say *Completed*
        /// rather than *Dismissed*, and `undoDone` needs it to know whether to
        /// un-complete remotely.
        static let completed = "completed"
    }

    func markDone(uid: String, reason: String = DoneReason.user) throws {
        guard let item = try item(uid: uid) else { return }
        item.doneAt = .now
        item.doneReason = reason
        item.snoozedUntil = nil
        item.updatedAt = .now
        try modelContext.save()
    }

    /// Brings a done item back, and reports what it was done *for*.
    ///
    /// The return value is load-bearing rather than informational: ⌘Z on a
    /// completed to-do has to un-complete it in the source too, and the store
    /// is the only thing that still knows which kind of done this was by the
    /// time undo runs.
    @discardableResult
    func undoDone(uid: String) throws -> String? {
        guard let item = try item(uid: uid) else { return nil }
        let reason = item.doneReason
        item.doneAt = nil
        item.doneReason = nil
        item.updatedAt = .now
        try modelContext.save()
        return reason
    }

    func snooze(uid: String, until: Date) throws {
        guard let item = try item(uid: uid) else { return }
        item.snoozedUntil = until
        item.snoozeWakeNotifiedAt = nil
        item.updatedAt = .now
        try modelContext.save()
    }

    func togglePin(uid: String) throws {
        guard let item = try item(uid: uid) else { return }
        item.pinnedAt = item.pinnedAt == nil ? .now : nil
        item.updatedAt = .now
        try modelContext.save()
    }

    /// Stamps `seenAt` the first time an item holds the panel's selection.
    ///
    /// Idempotent: the stamp records when the user *first* laid eyes on it, so
    /// re-selecting a row must not move it. Returns whether anything changed,
    /// so callers can skip a redundant badge refresh.
    @discardableResult
    func markSeen(uid: String, at date: Date = .now) throws -> Bool {
        guard let item = try item(uid: uid), item.seenAt == nil,
            // An explicit "mark unread" outranks merely focusing the row,
            // otherwise the next arrow press would undo it.
            item.unreadHeldAt == nil
        else {
            return false
        }
        item.seenAt = date
        // Deliberately not touching `updatedAt`: that tracks changes to the
        // notification itself, and seeing one is not a change to it.
        try modelContext.save()
        return true
    }

    /// Flips an item between read and unread, and reports the state it landed in.
    ///
    /// Marking unread also sets `unreadHeldAt`, which is what makes the choice
    /// stick against `markSeen`; marking read clears the hold again.
    @discardableResult
    func toggleSeen(uid: String, at date: Date = .now) throws -> Bool {
        guard let item = try item(uid: uid) else { return false }
        if item.seenAt == nil {
            item.seenAt = date
            item.unreadHeldAt = nil
        } else {
            item.seenAt = nil
            item.unreadHeldAt = date
        }
        try modelContext.save()
        return item.seenAt != nil
    }

    /// The persisted first-seen stamp, or `nil` if the item is still unseen.
    func seenAt(uid: String) throws -> Date? {
        try item(uid: uid)?.seenAt
    }

    // MARK: Batch triage

    /// Mark several items done in **one** save.
    ///
    /// Not a loop over `markDone` at the call site, and the reason is motion
    /// rather than throughput: each save bumps `queueVersion`, and four bumps
    /// make a topic dismissal animate as four staggered row collapses instead
    /// of the one coordinated gesture `PanelMotion` exists to produce.
    ///
    /// The *write-throughs* stay per item — every source still has to be told
    /// individually, and that is `SyncEngine`'s job, not this one's.
    func markDone(uids: [String], reason: String = DoneReason.user) throws {
        guard !uids.isEmpty else { return }
        let wanted = Set(uids)
        for item in try items() where wanted.contains(item.uid) {
            item.doneAt = .now
            item.doneReason = reason
            item.snoozedUntil = nil
            item.updatedAt = .now
        }
        try modelContext.save()
    }

    func snooze(uids: [String], until: Date) throws {
        guard !uids.isEmpty else { return }
        let wanted = Set(uids)
        for item in try items() where wanted.contains(item.uid) {
            item.snoozedUntil = until
            item.snoozeWakeNotifiedAt = nil
            item.updatedAt = .now
        }
        try modelContext.save()
    }

    /// Pins or unpins several items to the *same* state.
    ///
    /// Normalizing rather than flipping each row: a mixed topic where ⌘P
    /// flipped every member individually would stay mixed forever, and
    /// "pin this topic" has to mean one thing. Same rule the main window
    /// already applies to a mixed multi-selection.
    func setPinned(uids: [String], pinned: Bool) throws {
        guard !uids.isEmpty else { return }
        let wanted = Set(uids)
        for item in try items() where wanted.contains(item.uid) {
            item.pinnedAt = pinned ? (item.pinnedAt ?? .now) : nil
            item.updatedAt = .now
        }
        try modelContext.save()
    }

    /// Brings several done items back, reporting what each was done *for*.
    ///
    /// The per-uid reason is what lets one ⌘Z over a mixed topic un-complete
    /// the Reminders member remotely while leaving the dismissed Slack member
    /// untouched.
    func undoDone(uids: [String]) throws -> [String: String] {
        guard !uids.isEmpty else { return [:] }
        let wanted = Set(uids)
        var reasons: [String: String] = [:]
        for item in try items() where wanted.contains(item.uid) {
            if let reason = item.doneReason { reasons[item.uid] = reason }
            item.doneAt = nil
            item.doneReason = nil
            item.updatedAt = .now
        }
        try modelContext.save()
        return reasons
    }

    /// Marks several items read or unread, normalized to the same state.
    ///
    /// Normalizing rather than flipping each, for the same reason as
    /// `setPinned`: "mark these read" has to mean one thing, and a mixed set
    /// flipped row-by-row stays mixed forever.
    ///
    /// Marking unread also sets `unreadHeldAt`, which is what makes the
    /// choice stick against the auto-seen `markSeen` the next time the
    /// selection lands on the row.
    func setSeen(uids: [String], seen: Bool, at date: Date = .now) throws {
        guard !uids.isEmpty else { return }
        let wanted = Set(uids)
        for item in try items() where wanted.contains(item.uid) {
            if seen {
                item.seenAt = item.seenAt ?? date
                item.unreadHeldAt = nil
            } else {
                item.seenAt = nil
                item.unreadHeldAt = date
            }
        }
        // Deliberately not touching `updatedAt`: reading a notification is
        // not a change to the notification.
        try modelContext.save()
    }

    // MARK: Topics

    /// Creates a topic and moves the given items into it.
    ///
    /// Terms **back-fill** over items that are not in a topic already: making
    /// a topic for `EPD-1873` should gather the three other rows that already
    /// mention it, not just the ones that happened to be marked. Items that
    /// belong to another topic are left alone — an explicit member always
    /// beats a rule.
    /// - Parameter id: supplied by the caller so the UI can select the new
    ///   topic in the same frame it asks for it, rather than waiting a round
    ///   trip through this actor to learn what it just made.
    @discardableResult
    func createTopic(
        id: String = UUID().uuidString, name: String, terms: [String] = [],
        memberUIDs: [String] = []
    ) throws -> String {
        let topic = Topic(id: id, name: name, terms: sanitized(terms))
        modelContext.insert(topic)
        try assign(uids: memberUIDs, to: topic.id, save: false)
        try backfill(topic: topic, save: false)
        try modelContext.save()
        return topic.id
    }

    func renameTopic(id: String, name: String, terms: [String]) throws {
        guard let topic = try topic(id: id) else { return }
        topic.name = name
        topic.terms = sanitized(terms)
        try backfill(topic: topic, save: false)
        try modelContext.save()
    }

    /// Dissolves a topic. Members go back to their own source sections; not
    /// one of them is done, dismissed or otherwise touched.
    func deleteTopic(id: String) throws {
        for item in try items() where item.topicID == id { item.topicID = nil }
        if let topic = try topic(id: id) { modelContext.delete(topic) }
        try modelContext.save()
    }

    func addToTopic(id: String, uids: [String]) throws {
        guard try topic(id: id) != nil else { return }
        try assign(uids: uids, to: id, save: true)
    }

    func removeFromTopic(uids: [String]) throws {
        try assign(uids: uids, to: nil, save: true)
    }

    /// uid → topic id, for everything currently grouped. Cheap enough to read
    /// per call: the panel already holds every queued item in memory.
    func topicMembership() throws -> [String: String] {
        try items().reduce(into: [:]) { map, item in
            if let id = item.topicID { map[item.uid] = id }
        }
    }

    private func assign(uids: [String], to topicID: String?, save: Bool) throws {
        guard !uids.isEmpty else { return }
        let wanted = Set(uids)
        for item in try items() where wanted.contains(item.uid) {
            item.topicID = topicID
            // Deliberately not touching `updatedAt`: that tracks changes to
            // the notification, and filing one is not a change to it.
        }
        if save { try modelContext.save() }
    }

    /// Pulls unassigned, undone items matching the topic's terms into it.
    private func backfill(topic: Topic, save: Bool) throws {
        guard !topic.terms.isEmpty else { return }
        for item in try items()
        where item.topicID == nil && item.doneAt == nil {
            let fields = TopicMatcher.Fields(
                title: item.title, snippet: item.snippet, url: item.urlString)
            if TopicMatcher.matches(topic.terms, fields) {
                item.topicID = topic.id
            }
        }
        if save { try modelContext.save() }
    }

    private func sanitized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func topic(id: String) throws -> Topic? {
        var descriptor = FetchDescriptor<Topic>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// The catch rules, as plain values — so the matching in `reconcile` and
    /// `apply` never faults a model object per arriving item.
    private func topicRules() throws -> [(id: String, terms: [String])] {
        try modelContext.fetch(FetchDescriptor<Topic>())
            .filter { !$0.terms.isEmpty }
            .map { ($0.id, $0.terms) }
    }

    /// Which topic a *newly arriving* item joins, if any.
    ///
    /// Runs on insert only. Re-running it on every poll would undo a manual
    /// removal on the next refresh — the user takes a row out of a topic and
    /// the rule silently puts it back — which is the same "explicit beats
    /// rule" invariant, seen from the other side.
    nonisolated static func topicID(
        matching remote: RemoteItem, in rules: [(id: String, terms: [String])]
    ) -> String? {
        guard !rules.isEmpty else { return nil }
        let fields = TopicMatcher.Fields(
            title: remote.title, snippet: remote.snippet, url: remote.url)
        return rules.first { TopicMatcher.matches($0.terms, fields) }?.id
    }

    // MARK: Maintenance

    /// Snoozes past their wake time that haven't fired a banner yet.
    /// Marks them notified and returns them — waking always banners.
    func dueSnoozeWakes(now: Date = .now) throws -> [ItemSummary] {
        let due = try items().filter {
            $0.doneAt == nil && $0.snoozeWakeNotifiedAt == nil
                && ($0.snoozedUntil.map { $0 <= now } ?? false)
        }
        for item in due {
            item.snoozeWakeNotifiedAt = now
            item.snoozedUntil = nil
        }
        if !due.isEmpty { try modelContext.save() }
        return due.map(summary)
    }

    /// Purge done items older than the 90-day retention. Pins are immortal.
    func purge(now: Date = .now) throws -> Int {
        let cutoff = TriagePolicy.purgeCutoff(now: now)
        let surviving = try items()
        let victims = surviving.filter {
            !$0.isPinned && ($0.doneAt.map { $0 < cutoff } ?? false)
        }
        for item in victims { modelContext.delete(item) }

        // Topics are allowed to be empty — that is their resting state
        // between the last member archiving and the next matching item
        // arriving, and deleting one then would break the rule that a topic
        // outlives its members. So emptiness alone is not grounds; age is
        // the second half of the test.
        let purged = Set(victims.map(\.uid))
        let stillReferenced = Set(
            surviving.filter { !purged.contains($0.uid) }
                .compactMap(\.topicID))
        let staleTopics = try modelContext.fetch(FetchDescriptor<Topic>())
            .filter {
                !stillReferenced.contains($0.id)
                    && $0.createdAt < TopicPolicy.purgeCutoff(now: now)
            }
        for topic in staleTopics { modelContext.delete(topic) }

        if !victims.isEmpty || !staleTopics.isEmpty { try modelContext.save() }
        return victims.count
    }

    // MARK: Counts (for the badge)

    /// What the menu bar badge says is waiting.
    ///
    /// **A topic counts as one.** The badge answers "how much is waiting",
    /// and the premise of grouping is that four notifications about one thing
    /// are one thing — a badge still reading 54 while the queue shows a
    /// single row would make the queue the liar. A topic is high-signal when
    /// any of its active members is.
    ///
    /// A topic with a single active member counts one either way, which is
    /// also exactly how it renders (`TopicPolicy.minimumVisibleMembers`).
    ///
    /// **An auto-grouping fold counts as one too**, by the same sentence: for
    /// a source in `groupingSourceIDs`, rows sharing a `groupKey` are one.
    /// Expect the number to drop hard when grouping is first turned on —
    /// Slack from 188 to 49 in one measured week — which is the feature
    /// working, not the badge breaking.
    func badgeCounts(
        countedSourceIDs: Set<String>, groupingSourceIDs: Set<String> = []
    ) throws -> (total: Int, highSignal: Int) {
        let active = try items().filter {
            $0.isActive && countedSourceIDs.contains($0.sourceID)
        }
        var loose = 0
        var loudLoose = 0
        var topicIDs = Set<String>()
        var loudTopicIDs = Set<String>()
        var foldIDs = Set<String>()
        var loudFoldIDs = Set<String>()
        for item in active {
            if let id = item.topicID {
                topicIDs.insert(id)
                if item.highSignal { loudTopicIDs.insert(id) }
            } else if groupingSourceIDs.contains(item.sourceID),
                let key = item.groupKey, !key.isEmpty
            {
                let id = TopicGroup.foldID(sourceID: item.sourceID, key: key)
                foldIDs.insert(id)
                if item.highSignal { loudFoldIDs.insert(id) }
            } else {
                loose += 1
                if item.highSignal { loudLoose += 1 }
            }
        }
        return (
            loose + topicIDs.count + foldIDs.count,
            loudLoose + loudTopicIDs.count + loudFoldIDs.count
        )
    }

    // MARK: Helpers

    private func items(sourceID: String? = nil) throws -> [Item] {
        var descriptor = FetchDescriptor<Item>()
        if let sourceID {
            descriptor.predicate = #Predicate { $0.sourceID == sourceID }
        }
        return try modelContext.fetch(descriptor)
    }

    private func item(uid: String) throws -> Item? {
        var descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// A done item comes back when (a) the remote cleared it and it
    /// reappeared, or (b) NEW activity arrived after the user did it away —
    /// external ids like Slack "dm-<channel>" are reused per conversation,
    /// so a fresh message must resurrect an explicitly-done item.
    /// Revives a done item the source has spoken about again, and reports
    /// whether it actually did.
    ///
    /// The Bool is what lets a revival be made *visible*. Banners and journal
    /// arrivals both key off `ReconcileResult.inserted`, and a resurrected
    /// item otherwise slides back into the queue with no banner and no
    /// journal line. Whether that silence is a bug depends on the source, so
    /// the caller decides via `.announcesReturn`: for `local` a revival is
    /// the normal way a Claude Code session says it is waiting again and must
    /// be announced, while for a polled remote source it is routine
    /// bookkeeping and announcing it would be noise.
    ///
    /// It reports at most once per revival either way: the first call clears
    /// `doneAt`, so subsequent polls take the `guard` and report nothing.
    @discardableResult
    private func resurrectIfNeeded(_ item: Item, from remote: RemoteItem) -> Bool {
        guard let doneAt = item.doneAt else { return false }
        guard item.doneReason == DoneReason.remote || remote.occurredAt > doneAt else {
            return false
        }
        item.doneAt = nil
        item.doneReason = nil
        item.updatedAt = .now
        return true
    }

    private func update(_ item: Item, from remote: RemoteItem) {
        // `kind` is refreshed like every other field: the source is
        // authoritative about what an item *is*, and a Claude Code row now
        // lives long enough to change (claude_done → claude_waiting when an
        // idle session starts asking). Freezing it at insert left the main
        // window's Kind column showing whatever the row happened to be born as.
        item.kind = remote.kind
        item.title = remote.title
        item.snippet = remote.snippet
        item.urlString = remote.url
        item.actorName = remote.actorName
        item.occurredAt = remote.occurredAt
        item.highSignal = remote.highSignal
        item.payload = remote.payload
        // Refreshed on purpose, unlike `topicID` just above this method's
        // callers: the source owns what an item is about, and a poll is how
        // a renamed channel or retitled issue comes to read correctly.
        item.groupKey = remote.groupKey
        item.groupLabel = remote.groupLabel
        item.updatedAt = .now
    }

    private func summary(_ item: Item) -> ItemSummary {
        ItemSummary(
            id: item.uid, sourceID: item.sourceID,
            sourceKind: item.sourceKind, title: item.title,
            snippet: item.snippet, urlString: item.urlString,
            highSignal: item.highSignal)
    }
}
