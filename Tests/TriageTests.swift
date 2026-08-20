import Foundation
import SwiftData
import Testing

@testable import InboxAndChill

@MainActor
struct TriageTests {
    private func makeStore() throws -> Store {
        let container = try ModelContainer(
            for: Item.self, SourceConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return Store(modelContainer: container)
    }

    @Test func reconcileInsertsAndRemoteClears() async throws {
        let store = try makeStore()
        let a = RemoteItem(
            externalID: "a", kind: "mention", title: "A", occurredAt: .now,
            highSignal: true)
        let b = RemoteItem(
            externalID: "b", kind: "dm", title: "B", occurredAt: .now,
            highSignal: false)
        let r1 = try await store.reconcile(
            snapshot: [a, b], sourceID: "s", sourceKind: "test",
            remoteTruth: true)
        #expect(r1.inserted.count == 2)

        // b vanishes from the remote snapshot → auto-archived (hybrid rule).
        let r2 = try await store.reconcile(
            snapshot: [a], sourceID: "s", sourceKind: "test", remoteTruth: true)
        #expect(r2.clearedRemotely == 1)

        // b reappears → resurrects silently. A source without
        // `.announcesReturn` (every remote one today) treats a return as
        // routine bookkeeping: back in the queue, no banner, no journal line.
        let r3 = try await store.reconcile(
            snapshot: [a, b], sourceID: "s", sourceKind: "test",
            remoteTruth: true)
        #expect(r3.inserted.isEmpty)
        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 2 && counts.highSignal == 1)
    }

    @Test func pinnedItemsSurviveRemoteClearAndPurge() async throws {
        let store = try makeStore()
        let a = RemoteItem(
            externalID: "a", kind: "mention", title: "A", occurredAt: .now)
        _ = try await store.reconcile(
            snapshot: [a], sourceID: "s", sourceKind: "test", remoteTruth: true)
        try await store.togglePin(uid: "test:a")

        // Remote clears everything; pinned item must survive.
        let r = try await store.reconcile(
            snapshot: [], sourceID: "s", sourceKind: "test", remoteTruth: true)
        #expect(r.clearedRemotely == 0)
        let purged = try await store.purge(now: .now.addingTimeInterval(200 * 24 * 3600))
        #expect(purged == 0)
    }

    @Test("Seeing an item stamps it once and never moves the stamp")
    func seenStampIsIdempotent() async throws {
        let store = try makeStore()
        _ = try await store.reconcile(
            snapshot: [
                RemoteItem(
                    externalID: "a", kind: "mention", title: "A",
                    occurredAt: .now, highSignal: true)
            ], sourceID: "s", sourceKind: "test", remoteTruth: true)

        let uid = "test:a"
        let first = Date(timeIntervalSince1970: 1_000)
        #expect(try await store.markSeen(uid: uid, at: first) == true)

        // Re-focusing a row must not re-date it: the stamp records when it was
        // FIRST seen, and a later write would corrupt that.
        #expect(try await store.markSeen(uid: uid, at: .now) == false)
        #expect(try await store.seenAt(uid: uid) == first)
    }

    @Test("Arriving items start unseen, so nothing is silently pre-read")
    func newItemsArriveUnseen() async throws {
        let store = try makeStore()
        let result = try await store.reconcile(
            snapshot: [
                RemoteItem(
                    externalID: "a", kind: "mention", title: "A",
                    occurredAt: .now, highSignal: true)
            ], sourceID: "s", sourceKind: "test", remoteTruth: true)
        #expect(result.inserted.count == 1)
        #expect(try await store.seenAt(uid: "test:a") == nil)
    }

    @Test("U flips an item both ways, and the unread choice outranks focus")
    func toggleUnreadHoldsAgainstFocus() async throws {
        let store = try makeStore()
        _ = try await store.reconcile(
            snapshot: [
                RemoteItem(
                    externalID: "a", kind: "mention", title: "A",
                    occurredAt: .now, highSignal: true)
            ], sourceID: "s", sourceKind: "test", remoteTruth: true)
        let uid = "test:a"

        // Focus marks it read.
        #expect(try await store.markSeen(uid: uid) == true)
        #expect(try await store.seenAt(uid: uid) != nil)

        // U marks it unread again.
        #expect(try await store.toggleSeen(uid: uid) == false)
        #expect(try await store.seenAt(uid: uid) == nil)

        // The whole point: arrowing back onto the row must NOT silently
        // re-read it, or "mark unread" would survive about one keystroke.
        #expect(try await store.markSeen(uid: uid) == false)
        #expect(try await store.seenAt(uid: uid) == nil)

        // U again marks it read and releases the hold, so focus works anew.
        #expect(try await store.toggleSeen(uid: uid) == true)
        #expect(try await store.seenAt(uid: uid) != nil)
        #expect(try await store.toggleSeen(uid: uid) == false)
        #expect(try await store.markSeen(uid: uid) == false)
    }

    @Test func doneUndoAndPurge() async throws {
        let store = try makeStore()
        let a = RemoteItem(
            externalID: "a", kind: "mention", title: "A", occurredAt: .now)
        _ = try await store.reconcile(
            snapshot: [a], sourceID: "s", sourceKind: "test",
            remoteTruth: false)
        try await store.markDone(uid: "test:a")
        var counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 0)

        try await store.undoDone(uid: "test:a")
        counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 1)

        try await store.markDone(uid: "test:a")
        // Not yet 90 days → survives purge; after 91 days → purged.
        #expect(try await store.purge() == 0)
        let purged = try await store.purge(
            now: .now.addingTimeInterval(91 * 24 * 3600))
        #expect(purged == 1)
    }

    @Test func newActivityResurrectsUserDoneItem() async throws {
        // Slack-style reused external ids: a fresh message in a conversation
        // the user previously did away must bring the item back.
        let store = try makeStore()
        let dm = RemoteItem(
            externalID: "dm-C1", kind: "dm", title: "DM: maria",
            occurredAt: .now.addingTimeInterval(-100))
        _ = try await store.apply(
            event: .upsert([dm]), sourceID: "s", sourceKind: "slack",
            remoteTruth: true)
        try await store.markDone(uid: "slack:dm-C1")

        // Same-age upsert (e.g. reconnect replay) must NOT resurrect.
        _ = try await store.apply(
            event: .upsert([dm]), sourceID: "s", sourceKind: "slack",
            remoteTruth: true)
        var counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 0)

        // Newer activity must resurrect.
        var fresh = dm
        fresh.occurredAt = .now.addingTimeInterval(100)
        _ = try await store.apply(
            event: .upsert([fresh]), sourceID: "s", sourceKind: "slack",
            remoteTruth: true)
        counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 1)
    }

    @Test("An announcing source reports a return once, not on every later poll")
    func resurrectionReportsOnce() async throws {
        // The Claude Code case that motivated `.announcesReturn`: one row per
        // session means the second and later "Claude finished" events revive
        // an existing row instead of inserting a new one. Banners key off
        // `inserted`, so without this the very first finish was the only one
        // that ever reached the user.
        let store = try makeStore()
        var session = RemoteItem(
            externalID: "claude-abc", kind: "claude_done",
            title: "Claude finished in repo",
            occurredAt: .now.addingTimeInterval(-100))
        _ = try await store.apply(
            event: .upsert([session]), sourceID: "s", sourceKind: "local",
            remoteTruth: false, announcesReturn: true)

        // The user replied: UserPromptSubmit clears the row.
        _ = try await store.apply(
            event: .clear(["claude-abc"]), sourceID: "s", sourceKind: "local",
            remoteTruth: false)

        // Claude finishes again → the row comes back, and says so.
        session.occurredAt = .now
        session.title = "Claude finished in repo"
        let revived = try await store.apply(
            event: .upsert([session]), sourceID: "s", sourceKind: "local",
            remoteTruth: false, announcesReturn: true)
        #expect(revived.inserted.map(\.id) == ["local:claude-abc"])

        // Still finished, nothing new: an already-live row is not an arrival.
        let again = try await store.apply(
            event: .upsert([session]), sourceID: "s", sourceKind: "local",
            remoteTruth: false, announcesReturn: true)
        #expect(again.inserted.isEmpty)
    }

    @Test("Without the capability the same return stays silent")
    func resurrectionIsSilentByDefault() async throws {
        // The scope guard. Every remote source is on this path, so a
        // regression that made returns announce everywhere would show up here
        // rather than as banner noise on Brandon's machine.
        let store = try makeStore()
        var item = RemoteItem(
            externalID: "issue-1", kind: "error", title: "Boom",
            occurredAt: .now.addingTimeInterval(-100))
        _ = try await store.apply(
            event: .upsert([item]), sourceID: "s", sourceKind: "sentry",
            remoteTruth: true)
        try await store.markDone(uid: "sentry:issue-1")

        item.occurredAt = .now
        let back = try await store.apply(
            event: .upsert([item]), sourceID: "s", sourceKind: "sentry",
            remoteTruth: true)
        #expect(back.inserted.isEmpty)

        // Silent, but genuinely back in the queue — not dropped.
        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 1)
    }

    @Test("A source that changes an item's kind is believed")
    func kindIsRefreshed() async throws {
        // A Claude Code row outlives the state it was born in: it appears as
        // claude_done and becomes claude_waiting when the idle session starts
        // asking. Freezing `kind` at insert left the Kind column lying.
        let container = try ModelContainer(
            for: Item.self, SourceConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = Store(modelContainer: container)

        var item = RemoteItem(
            externalID: "claude-abc", kind: "claude_done", title: "Finished",
            occurredAt: .now.addingTimeInterval(-10))
        _ = try await store.apply(
            event: .upsert([item]), sourceID: "s", sourceKind: "local",
            remoteTruth: false)

        item.kind = "claude_waiting"
        item.title = "Claude needs your input"
        item.occurredAt = .now
        _ = try await store.apply(
            event: .upsert([item]), sourceID: "s", sourceKind: "local",
            remoteTruth: false)

        let stored = try ModelContext(container).fetch(FetchDescriptor<Item>())
        #expect(stored.count == 1)
        #expect(stored.first?.kind == "claude_waiting")
        #expect(stored.first?.title == "Claude needs your input")
    }

    @Test func snoozeWakeFiresOnce() async throws {
        let store = try makeStore()
        let a = RemoteItem(
            externalID: "a", kind: "mention", title: "A", occurredAt: .now)
        _ = try await store.reconcile(
            snapshot: [a], sourceID: "s", sourceKind: "test",
            remoteTruth: false)
        try await store.snooze(uid: "test:a", until: .now.addingTimeInterval(-1))
        let wakes = try await store.dueSnoozeWakes()
        #expect(wakes.count == 1)
        #expect(try await store.dueSnoozeWakes().isEmpty)
    }
    // MARK: - Partial-snapshot protection
    //
    // Regression coverage for the GitHub resurrection bug. `GET /notifications`
    // caps at 50 items per page (default *and* max), and the connector used to
    // fetch only the first page. With `.remoteTruth`, every unread notification
    // past #50 looked like one the user had cleared remotely, got auto-archived
    // with `doneReason == "remote"`, and then sprang back the moment the window
    // slid far enough for it to reappear — so items could never be dismissed
    // for good. SyncEngine now suspends remote-truth archiving for any cycle
    // where the connector reports an incomplete snapshot.

    @Test("A partial snapshot must not archive the items it omits")
    func partialSnapshotDoesNotArchive() async throws {
        let store = try makeStore()
        let page1 = (1...3).map {
            RemoteItem(externalID: "p\($0)", kind: "pr", title: "P\($0)", occurredAt: .now)
        }
        let page2 = (4...6).map {
            RemoteItem(externalID: "p\($0)", kind: "pr", title: "P\($0)", occurredAt: .now)
        }
        _ = try await store.reconcile(
            snapshot: page1 + page2, sourceID: "s", sourceKind: "test",
            remoteTruth: true)

        // Only page 1 comes back, and the connector said the snapshot was
        // incomplete — so SyncEngine passes remoteTruth: false.
        let partial = try await store.reconcile(
            snapshot: page1, sourceID: "s", sourceKind: "test", remoteTruth: false)
        #expect(partial.clearedRemotely == 0)
        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 6)
    }

    @Test("The same omission with a complete snapshot does archive")
    func completeSnapshotStillArchives() async throws {
        let store = try makeStore()
        let a = RemoteItem(externalID: "a", kind: "pr", title: "A", occurredAt: .now)
        let b = RemoteItem(externalID: "b", kind: "pr", title: "B", occurredAt: .now)
        _ = try await store.reconcile(
            snapshot: [a, b], sourceID: "s", sourceKind: "test", remoteTruth: true)
        let result = try await store.reconcile(
            snapshot: [a], sourceID: "s", sourceKind: "test", remoteTruth: true)
        #expect(result.clearedRemotely == 1)
    }

    /// "How do I get rid of these permanently?" — a thing the user marked done
    /// must stay done even while the remote keeps listing it as unread (a failed
    /// or not-yet-propagated write-through), because its remote timestamp hasn't
    /// moved. Only genuinely newer remote activity may bring it back.
    @Test("A user-marked-done item stays done while the remote still lists it")
    func userDoneSurvivesRemoteStillListing() async throws {
        let store = try makeStore()
        let old = Date.now.addingTimeInterval(-3600)
        let item = RemoteItem(
            externalID: "keep-gone", kind: "pr", title: "Old PR", occurredAt: old)
        _ = try await store.reconcile(
            snapshot: [item], sourceID: "s", sourceKind: "test", remoteTruth: true)
        try await store.markDone(uid: item.uid(sourceKind: "test"))

        // Three more polls with the remote still reporting it unread.
        for _ in 0..<3 {
            _ = try await store.reconcile(
                snapshot: [item], sourceID: "s", sourceKind: "test", remoteTruth: true)
        }
        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 0)
    }

    @Test("Genuinely newer remote activity does bring a done item back")
    func newerRemoteActivityResurrects() async throws {
        let store = try makeStore()
        let old = Date.now.addingTimeInterval(-3600)
        let item = RemoteItem(
            externalID: "revive", kind: "pr", title: "PR", occurredAt: old)
        _ = try await store.reconcile(
            snapshot: [item], sourceID: "s", sourceKind: "test", remoteTruth: true)
        try await store.markDone(uid: item.uid(sourceKind: "test"))

        var updated = item
        updated.occurredAt = .now  // someone commented again
        _ = try await store.reconcile(
            snapshot: [updated], sourceID: "s", sourceKind: "test", remoteTruth: true)
        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 1)
    }

    @Test("Connectors report complete snapshots unless they say otherwise")
    func snapshotCompletenessDefault() async throws {
        #expect(await FakeConnector(sourceID: "f").snapshotWasComplete())
    }
}
