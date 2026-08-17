import Foundation
import SwiftData

/// Lightweight value snapshot of an Item, safe to pass across actors.
struct ItemSummary: Sendable, Identifiable {
    var id: String  // uid
    var sourceID: String
    var sourceKind: String
    var title: String
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
        remoteTruth: Bool
    ) throws -> ReconcileResult {
        var result = ReconcileResult()
        let existing = try items(sourceID: sourceID)
        var seen = Set<String>()

        for remote in snapshot {
            let uid = remote.uid(sourceKind: sourceKind)
            seen.insert(uid)
            if let item = existing.first(where: { $0.uid == uid }) {
                resurrectIfNeeded(item, from: remote)
                update(item, from: remote)
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
                item.doneReason = "remote"
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
        remoteTruth: Bool
    ) throws -> ReconcileResult {
        switch event {
        case .snapshot(let items):
            return try reconcile(
                snapshot: items, sourceID: sourceID, sourceKind: sourceKind,
                remoteTruth: remoteTruth)
        case .upsert(let remotes):
            var result = ReconcileResult()
            let existing = try items(sourceID: sourceID)
            for remote in remotes {
                let uid = remote.uid(sourceKind: sourceKind)
                if let item = existing.first(where: { $0.uid == uid }) {
                    resurrectIfNeeded(item, from: remote)
                    update(item, from: remote)
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
                item.doneReason = "remote"
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

    func markDone(uid: String) throws {
        guard let item = try item(uid: uid) else { return }
        item.doneAt = .now
        item.doneReason = "user"
        item.snoozedUntil = nil
        item.updatedAt = .now
        try modelContext.save()
    }

    func undoDone(uid: String) throws {
        guard let item = try item(uid: uid) else { return }
        item.doneAt = nil
        item.doneReason = nil
        item.updatedAt = .now
        try modelContext.save()
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
    private func resurrectIfNeeded(_ item: Item, from remote: RemoteItem) {
        guard let doneAt = item.doneAt else { return }
        if item.doneReason == "remote" || remote.occurredAt > doneAt {
            item.doneAt = nil
            item.doneReason = nil
            item.updatedAt = .now
        }
    }

    private func update(_ item: Item, from remote: RemoteItem) {
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
            urlString: item.urlString, highSignal: item.highSignal)
    }
}
