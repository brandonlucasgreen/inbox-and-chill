import Foundation

/// A snapshot item as reported by a connector. Value type; the SyncEngine
/// reconciles these into SwiftData `Item`s.
struct RemoteItem: Sendable, Equatable {
    var externalID: String
    var kind: String
    var title: String
    var snippet: String? = nil
    var url: String? = nil
    var actorName: String? = nil
    var occurredAt: Date
    var highSignal: Bool = false
    var payload: Data? = nil

    func uid(sourceKind: String) -> String { "\(sourceKind):\(externalID)" }
}

struct ConnectorCapabilities: OptionSet, Sendable {
    let rawValue: Int
    /// Connector can mark an item read/done in the remote service.
    static let markDone = ConnectorCapabilities(rawValue: 1 << 0)
    /// Connector can snooze remotely (Linear only, today).
    static let remoteSnooze = ConnectorCapabilities(rawValue: 1 << 1)
    /// The remote read-state is truth: items absent from the latest snapshot
    /// were handled in the service and auto-archive locally (hybrid rule —
    /// decision §2.1.2). Local-push sources lack this; their items die only
    /// by explicit done or an explicit clear event.
    static let remoteTruth = ConnectorCapabilities(rawValue: 1 << 2)
    /// Push connector: delivers events; SyncEngine skips interval polling.
    static let push = ConnectorCapabilities(rawValue: 1 << 3)
}

/// Events a push connector can emit between full snapshots.
enum ConnectorEvent: Sendable {
    /// Upsert these items into the queue.
    case upsert([RemoteItem])
    /// The remote cleared these ids (e.g. Slack read, reaction removed).
    case clear([String])
    /// Replace the full snapshot (same semantics as a `fetch()` result).
    case snapshot([RemoteItem])
    case status(ConnectorStatus)
}

enum ConnectorStatus: Sendable, Equatable {
    case ok(Date)
    case error(String)
    case connecting
}

/// One service connection. Implementations are actors; all methods are
/// invoked by the SyncEngine, never by UI directly.
protocol Connector: Actor {
    nonisolated var sourceID: String { get }
    nonisolated var sourceKind: String { get }
    nonisolated var capabilities: ConnectorCapabilities { get }
    /// Poll cadence for non-push connectors.
    nonisolated var pollInterval: TimeInterval { get }

    /// Full snapshot of the current remote queue (unread/actionable only).
    func fetch() async throws -> [RemoteItem]
    /// Write-through done. No-op unless `.markDone`.
    func markDone(externalID: String, payload: Data?) async throws
    /// Write-through snooze. No-op unless `.remoteSnooze`.
    func snooze(externalID: String, until: Date, payload: Data?) async throws
    /// Start a push connection, delivering events via `emit`. Runs until
    /// cancelled. Default implementation returns immediately (poll-only).
    func run(emit: @escaping @Sendable (ConnectorEvent) -> Void) async
}

extension Connector {
    nonisolated var pollInterval: TimeInterval { 45 }
    func markDone(externalID: String, payload: Data?) async throws {}
    func snooze(externalID: String, until: Date, payload: Data?) async throws {}
    func run(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {}
}
