import Foundation

/// Push connector for same-machine producers (the `inchill` CLI, Claude Code
/// hooks). Owns the lifecycle of the shared `LocalListener` while running and
/// translates its HTTP posts into `ConnectorEvent`s.
///
/// No `.remoteTruth`: unlike Linear/GitHub/Slack, nothing here has a remote
/// read-state to diff against. A local item lives until the user does it, or
/// until an explicit `/clear` post says otherwise (see the Claude Code
/// waiting→done convention in `ClaudeCodeIntegration.swift`).
actor LocalConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "local"
    nonisolated let capabilities: ConnectorCapabilities = [.push]

    init(sourceID: String = "local") {
        self.sourceID = sourceID
    }

    func fetch() async throws -> [RemoteItem] { [] }

    func run(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {
        let generation: UInt64
        do {
            generation = try await LocalListener.shared.start(
                onNotify: { payload in
                    let item = RemoteItem(
                        externalID: payload.id ?? UUID().uuidString,
                        kind: payload.kind ?? "custom",
                        title: payload.title,
                        snippet: payload.body,
                        url: payload.url,
                        occurredAt: .now,
                        highSignal: payload.highSignal ?? true)
                    emit(.upsert([item]))
                },
                onClear: { payload in
                    emit(.clear([payload.id]))
                })
        } catch {
            emit(.status(.error(String(describing: error))))
            return
        }

        emit(.status(.ok(.now)))

        // The listener runs on its own dispatch queue independent of this
        // task, but we hold the task open — and the listener alive — until
        // SyncEngine cancels us (e.g. the source is disabled/removed).
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        await LocalListener.shared.stop(generation: generation)
    }
}
