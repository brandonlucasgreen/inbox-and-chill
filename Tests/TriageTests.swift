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

    // MARK: To-do sources — dismissal, completion, recurrence
    //
    // These four are the store-level half of the design in
    // docs/todo-sources-plan.md. Both failure modes they guard are silent: a
    // dismissal that will not stick, and a repeating task that disappears
    // forever after being completed once.

    @Test("Dismissing a task keeps it dismissed, poll after poll")
    func dismissedTaskStaysDismissed() async throws {
        // The trap. A reminder due later today is still in every snapshot
        // after you dismiss it, so `resurrectIfNeeded` gets asked about it on
        // every poll — and if `occurredAt` were the due date it would say yes
        // and un-dismiss the row a minute later.
        let store = try makeStore()
        let now = Date.now
        let task = TodoTask(
            providerID: "REM-1", title: "Call the dentist", listName: "Family",
            due: now.addingTimeInterval(3 * 3600),
            createdAt: now.addingTimeInterval(-86_400),
            modifiedAt: now.addingTimeInterval(-3_600))
        let remote = TodoItemMapper.remoteItem(from: task, now: now)

        _ = try await store.reconcile(
            snapshot: [remote], sourceID: "s", sourceKind: "reminders",
            remoteTruth: true)
        try await store.markDone(uid: "reminders:REM-1")

        // Two more polls, the task unchanged and still incomplete in Reminders.
        for _ in 0..<2 {
            _ = try await store.reconcile(
                snapshot: [remote], sourceID: "s", sourceKind: "reminders",
                remoteTruth: true)
        }
        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(
            counts.total == 0,
            "a dismissed reminder came back — occurredAt is in the future again")
    }

    @Test("A repeating task's next occurrence arrives as a new row")
    func recurringTaskReturnsAsANewRow() async throws {
        // Measured: completing a recurring reminder rolls its due date forward
        // and leaves `lastModifiedDate` untouched. So identity is the only
        // thing that can distinguish tomorrow's occurrence from today's.
        let store = try makeStore()
        let now = Date.now
        let modified = now.addingTimeInterval(-600)
        let today = TodoTask(
            providerID: "REM-R", title: "Water the plants", listName: "House",
            due: now.addingTimeInterval(3_600), isRecurring: true,
            createdAt: now.addingTimeInterval(-86_400 * 30), modifiedAt: modified)
        var tomorrow = today
        tomorrow.due = now.addingTimeInterval(86_400 + 3_600)
        // Same providerID, same modifiedAt — exactly what the spike observed.
        tomorrow.modifiedAt = modified

        let first = TodoItemMapper.remoteItem(from: today, now: now)
        _ = try await store.reconcile(
            snapshot: [first], sourceID: "s", sourceKind: "reminders",
            remoteTruth: true)
        try await store.markDone(
            uid: "reminders:\(first.externalID)",
            reason: Store.DoneReason.completed)

        let second = TodoItemMapper.remoteItem(from: tomorrow, now: now)
        #expect(second.externalID != first.externalID)
        let result = try await store.reconcile(
            snapshot: [second], sourceID: "s", sourceKind: "reminders",
            remoteTruth: true)
        #expect(
            result.inserted.count == 1,
            "tomorrow's occurrence did not arrive — a daily reminder would vanish")

        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 1)
    }

    @Test("Completing and dismissing are told apart in the archive")
    func doneReasonDistinguishesCompletionFromDismissal() async throws {
        let store = try makeStore()
        let now = Date.now
        let items = ["REM-A", "REM-B"].map { id in
            TodoItemMapper.remoteItem(
                from: TodoTask(
                    providerID: id, title: id, listName: "Buffer",
                    due: now.addingTimeInterval(3_600),
                    modifiedAt: now.addingTimeInterval(-60)), now: now)
        }
        _ = try await store.reconcile(
            snapshot: items, sourceID: "s", sourceKind: "reminders",
            remoteTruth: true)

        try await store.markDone(uid: "reminders:REM-A")
        try await store.markDone(
            uid: "reminders:REM-B", reason: Store.DoneReason.completed)

        // `undoDone` reporting the reason is what lets ⌘Z decide whether to
        // reopen the task in Reminders. Without it undo half-works in silence.
        let dismissed = try await store.undoDone(uid: "reminders:REM-A")
        let completed = try await store.undoDone(uid: "reminders:REM-B")
        #expect(dismissed == Store.DoneReason.user)
        #expect(completed == Store.DoneReason.completed)
    }

    @Test("A completed task does not resurrect on the next poll")
    func completedTaskStaysDone() async throws {
        // `.remoteTruth` would normally archive an absent item, but a completed
        // reminder leaves the incomplete snapshot entirely — so the row has to
        // stay done rather than flicker.
        let store = try makeStore()
        let now = Date.now
        let remote = TodoItemMapper.remoteItem(
            from: TodoTask(
                providerID: "REM-C", title: "File expenses", listName: "Buffer",
                due: now.addingTimeInterval(-3_600),
                modifiedAt: now.addingTimeInterval(-7_200)), now: now)

        _ = try await store.reconcile(
            snapshot: [remote], sourceID: "s", sourceKind: "reminders",
            remoteTruth: true)
        try await store.markDone(
            uid: "reminders:REM-C", reason: Store.DoneReason.completed)

        // Gone from Reminders' incomplete list, as a completed task is.
        _ = try await store.reconcile(
            snapshot: [], sourceID: "s", sourceKind: "reminders",
            remoteTruth: true)
        let counts = try await store.badgeCounts(countedSourceIDs: ["s"])
        #expect(counts.total == 0)
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
