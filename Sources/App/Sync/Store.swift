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
                    highSignal: remote.highSignal, payload: remote.payload)
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
                        highSignal: remote.highSignal, payload: remote.payload)
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
        let victims = try items().filter {
            !$0.isPinned && ($0.doneAt.map { $0 < cutoff } ?? false)
        }
        for item in victims { modelContext.delete(item) }
        if !victims.isEmpty { try modelContext.save() }
        return victims.count
    }

    // MARK: Counts (for the badge)

    func badgeCounts(countedSourceIDs: Set<String>) throws -> (
        total: Int, highSignal: Int
    ) {
        let active = try items().filter {
            $0.isActive && countedSourceIDs.contains($0.sourceID)
        }
        return (active.count, active.filter(\.highSignal).count)
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
