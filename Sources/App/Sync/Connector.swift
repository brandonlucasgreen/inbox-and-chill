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
    /// An item this source revives — one that was done and has been spoken
    /// about again — is announced as a fresh arrival: it banners and lands in
    /// the journal, instead of quietly reappearing in the queue.
    ///
    /// Opt-in per connector rather than the default, because for most sources
    /// a return is routine bookkeeping and would be noise. It is the *point*
    /// for `local`: a Claude Code session occupies one long-lived row, so
    /// every finish after the first revives that row rather than inserting
    /// one, and without this only the very first time a session waited on you
    /// would ever reach you. Brandon's call, 2026-08-20 — *"i'd rather keep
    /// it to specific sources, i want to see how other sources feel first.
    /// claude code is kind of unique imo"* — so widening this is a decision
    /// to take with him, not a tidy-up.
    static let announcesReturn = ConnectorCapabilities(rawValue: 1 << 4)
    /// Connector can build an `ItemContext` for an expanded row — richer
    /// detail (thread messages, labels, stack frames) fetched or decoded on
    /// demand when the user presses D. Opt-in so the panel never shows a
    /// loading state for a source that will always answer nothing.
    static let providesContext = ConnectorCapabilities(rawValue: 1 << 5)
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

    /// Whether the most recent `fetch()` returned the *entire* remote queue.
    ///
    /// A connector that pages through a large remote inbox and hits its page
    /// cap must answer `false`, because `.remoteTruth` reads absence from a
    /// snapshot as "the user dealt with this remotely" and archives it. On a
    /// partial snapshot that inference is wrong — the item was merely on a
    /// page we didn't fetch — and archiving it is destructive *and* sets up a
    /// resurrection loop once the window slides and the item reappears.
    func snapshotWasComplete() async -> Bool

    /// Richer detail for one item, built when the user fully expands its row
    /// (D). Only called when `.providesContext` is declared. `nil` means
    /// "nothing to add for this item" and renders as nothing; a throw is
    /// shown to the user with the error's description, so name the reason
    /// and what to do about it (rule 5).
    func context(externalID: String, payload: Data?) async throws -> ItemContext?
}

extension Connector {
    nonisolated var pollInterval: TimeInterval { 45 }
    /// Most connectors fetch everything in one call; only those that paginate
    /// need to override this.
    func snapshotWasComplete() async -> Bool { true }
    func markDone(externalID: String, payload: Data?) async throws {}
    func snooze(externalID: String, until: Date, payload: Data?) async throws {}
    func run(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {}
    func context(externalID: String, payload: Data?) async throws -> ItemContext? { nil }
}
