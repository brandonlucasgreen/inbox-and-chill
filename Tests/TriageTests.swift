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

        // b reappears → resurrects.
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
}
