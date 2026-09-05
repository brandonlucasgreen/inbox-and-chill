import Foundation

/// Generates a rotating queue of fake items so the full triage loop is
/// exercisable before any real connector exists.
///
/// **Opt-in, DEBUG only:** `INCHILL_FAKE=1` in the scheme's environment. It
/// used to register itself in any DEBUG build with no real source, and that
/// bit twice on 2026-09-04 once a fresh install meant *zero* sources: a
/// Debug build's first run filled the welcome with fakes, and — worse —
/// `xcodebuild test` runs the app as its test host, whose `bootstrapConnectors`
/// registered this connector and wrote fake rows into the **shared live
/// store** (Debug and Release use the same `store.sqlite`). Brandon saw
/// them in the installed Release app: *"i see a bunch of 'Fake' notifications
/// after a few seconds after the first open."* The test host no longer
/// bootstraps at all, and this connector now has to be asked for.
actor FakeConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "fake"
    nonisolated let capabilities: ConnectorCapabilities = [.markDone, .remoteTruth]
    nonisolated let pollInterval: TimeInterval = 20

    static let optInKey = "INCHILL_FAKE"

    /// Whether to register the fake source: only when asked for, only when
    /// no real source exists (a real queue never has fakes mixed in), and
    /// never under the test host. Pure, so the three conditions are pinned.
    nonisolated static func shouldRegister(
        configKinds: [String], environment: [String: String], runningTests: Bool
    ) -> Bool {
        guard !runningTests, environment[optInKey] != nil else { return false }
        return configKinds.allSatisfy { $0 == "local" }
    }

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
