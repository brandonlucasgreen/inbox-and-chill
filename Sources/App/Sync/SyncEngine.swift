import Foundation

/// What the engine tells the UI layer after the queue changes.
struct QueueChange: Sendable {
    var sourceID: String
    var inserted: [ItemSummary]
    var snoozeWakes: [ItemSummary]
    var status: ConnectorStatus?
}

/// Owns connectors and their poll/push lifecycles; reconciles into the Store.
/// UI-facing state (badge, banners) is derived on the MainActor by whoever
/// registered `onChange`.
actor SyncEngine {
    private let store: Store
    private var connectors: [String: any Connector] = [:]
    private var remoteTruth: [String: Bool] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var maintenanceTask: Task<Void, Never>?
    private let onChange: @Sendable (QueueChange) -> Void

    init(store: Store, onChange: @escaping @Sendable (QueueChange) -> Void) {
        self.store = store
        self.onChange = onChange
    }

    func register(_ connector: any Connector) async {
        let id = connector.sourceID
        await unregister(sourceID: id)
        connectors[id] = connector
        let caps = await connector.capabilities
        remoteTruth[id] = caps.contains(.remoteTruth)
        tasks[id] = Task { [weak self] in
            await self?.drive(connector, capabilities: caps)
        }
        startMaintenanceIfNeeded()
    }

    func unregister(sourceID: String) async {
        tasks[sourceID]?.cancel()
        tasks[sourceID] = nil
        connectors[sourceID] = nil
    }

    func refreshNow() async {
        for (id, connector) in connectors {
            let caps = await connector.capabilities
            guard !caps.contains(.push) else { continue }
            await pollOnce(connector, sourceID: id)
        }
    }

    // MARK: Triage write-through

    func markDone(uid: String, sourceID: String, externalID: String, payload: Data?) async {
        try? await store.markDone(uid: uid)
        if let connector = connectors[sourceID],
            await connector.capabilities.contains(.markDone) {
            try? await connector.markDone(externalID: externalID, payload: payload)
        }
        notify(sourceID: sourceID)
    }

    func undoDone(uid: String, sourceID: String) async {
        try? await store.undoDone(uid: uid)
        notify(sourceID: sourceID)
    }

    func snooze(uid: String, sourceID: String, externalID: String, until: Date, payload: Data?) async {
        try? await store.snooze(uid: uid, until: until)
        if let connector = connectors[sourceID],
            await connector.capabilities.contains(.remoteSnooze) {
            try? await connector.snooze(externalID: externalID, until: until, payload: payload)
        }
        notify(sourceID: sourceID)
    }

    // MARK: Lifecycles

    private func drive(_ connector: any Connector, capabilities: ConnectorCapabilities) async {
        let id = connector.sourceID
        if capabilities.contains(.push) {
            while !Task.isCancelled {
                await connector.run { [weak self] event in
                    Task { await self?.handle(event: event, sourceID: id) }
                }
                // run() returned (disconnect); back off briefly and restart.
                try? await Task.sleep(for: .seconds(5))
            }
        } else {
            let interval = await connector.pollInterval
            while !Task.isCancelled {
                await pollOnce(connector, sourceID: id)
                try? await Task.sleep(for: .seconds(interval + .random(in: 0...5)))
            }
        }
    }

    private func pollOnce(_ connector: any Connector, sourceID: String) async {
        do {
            let snapshot = try await connector.fetch()
            let result = try await store.reconcile(
                snapshot: snapshot, sourceID: sourceID,
                sourceKind: connector.sourceKind,
                remoteTruth: remoteTruth[sourceID] ?? false)
            onChange(QueueChange(
                sourceID: sourceID, inserted: result.inserted,
                snoozeWakes: [], status: .ok(.now)))
        } catch {
            onChange(QueueChange(
                sourceID: sourceID, inserted: [], snoozeWakes: [],
                status: .error(String(describing: error))))
        }
    }

    private func handle(event: ConnectorEvent, sourceID: String) async {
        guard let connector = connectors[sourceID] else { return }
        if case .status(let status) = event {
            onChange(QueueChange(sourceID: sourceID, inserted: [], snoozeWakes: [], status: status))
            return
        }
        do {
            let result = try await store.apply(
                event: event, sourceID: sourceID,
                sourceKind: connector.sourceKind,
                remoteTruth: remoteTruth[sourceID] ?? false)
            onChange(QueueChange(
                sourceID: sourceID, inserted: result.inserted,
                snoozeWakes: [], status: .ok(.now)))
        } catch {
            onChange(QueueChange(
                sourceID: sourceID, inserted: [], snoozeWakes: [],
                status: .error(String(describing: error))))
        }
    }

    /// Snooze wakes (checked each 30s) and daily purge.
    private func startMaintenanceIfNeeded() {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task { [store, onChange] in
            var lastPurge = Date.distantPast
            while !Task.isCancelled {
                if let wakes = try? await store.dueSnoozeWakes(), !wakes.isEmpty {
                    onChange(QueueChange(sourceID: "", inserted: [], snoozeWakes: wakes, status: nil))
                }
                if Date.now.timeIntervalSince(lastPurge) > 24 * 3600 {
                    _ = try? await store.purge()
                    lastPurge = .now
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func notify(sourceID: String) {
        onChange(QueueChange(sourceID: sourceID, inserted: [], snoozeWakes: [], status: nil))
    }
}
