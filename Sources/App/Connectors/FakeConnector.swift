import Foundation

/// Generates a rotating queue of fake items so the full triage loop is
/// exercisable before any real connector exists. Registered automatically
/// in DEBUG builds when no real sources are configured.
actor FakeConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "fake"
    nonisolated let capabilities: ConnectorCapabilities = [.markDone, .remoteTruth]
    nonisolated let pollInterval: TimeInterval = 20

    private var generation = 0
    private var cleared: Set<String> = []

    init(sourceID: String = "fake-1") {
        self.sourceID = sourceID
    }

    func fetch() async throws -> [RemoteItem] {
        generation += 1
        var items: [RemoteItem] = [
            RemoteItem(
                externalID: "mention-1", kind: "mention",
                title: "Maria mentioned you in #growth",
                snippet: "@brandon what do you think about the Q3 plan?",
                url: "https://example.com/1", actorName: "Maria",
                occurredAt: .now.addingTimeInterval(-3600), highSignal: true),
            RemoteItem(
                externalID: "review-1", kind: "review_requested",
                title: "Review requested: buffer/core #4821",
                snippet: "Fix rate limiter race condition",
                url: "https://example.com/2", actorName: "dev-bot",
                occurredAt: .now.addingTimeInterval(-7200), highSignal: true),
            RemoteItem(
                externalID: "assigned-1", kind: "assigned",
                title: "Assigned: INB-42 Panel keyboard navigation",
                url: "https://example.com/3", actorName: "Linear",
                occurredAt: .now.addingTimeInterval(-86400), highSignal: false),
        ]
        // Every few generations, a fresh item arrives.
        if generation > 1 {
            items.append(RemoteItem(
                externalID: "gen-\(generation / 3)", kind: "dm",
                title: "New fake DM #\(generation / 3)",
                url: "https://example.com/g\(generation)",
                occurredAt: .now, highSignal: generation % 2 == 0))
        }
        return items.filter { !cleared.contains($0.externalID) }
    }

    func markDone(externalID: String, payload: Data?) async throws {
        cleared.insert(externalID)
    }
}
