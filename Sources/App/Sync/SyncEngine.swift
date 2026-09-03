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
    private var announcesReturn: [String: Bool] = [:]
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
        let caps = connector.capabilities
        remoteTruth[id] = caps.contains(.remoteTruth)
        announcesReturn[id] = caps.contains(.announcesReturn)
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

    /// Stops every connector (trial expiry pauses syncing). Maintenance
    /// stays up on purpose: snooze wakes and the daily purge act on items
    /// already here, and an expired trial gates syncing, not triage.
    func unregisterAll() async {
        for sourceID in Array(tasks.keys) {
            await unregister(sourceID: sourceID)
        }
    }

    func refreshNow() async {
        for (id, connector) in connectors {
            let caps = connector.capabilities
            guard !caps.contains(.push) else { continue }
            await pollOnce(connector, sourceID: id)
        }
    }

    // MARK: Triage write-through

    /// Everything the engine needs to act on one row without holding the
    /// `Item` itself, which is not `Sendable`.
    struct Target: Sendable {
        var uid: String
        var sourceID: String
        var externalID: String
        var payload: Data?
    }

    /// Dismiss several rows — a topic, or a main-window multi-selection.
    ///
    /// **One local write, N write-throughs.** The store save is batched
    /// because each save bumps `queueVersion`, and four bumps turn one topic
    /// dismissal into four staggered row collapses (`PanelMotion`). The
    /// write-throughs cannot be batched and must not be: each source has to
    /// be told separately, and each can fail separately — a failure is
    /// reported against the source it belongs to, so one dead connector in a
    /// mixed topic names itself rather than tainting the rest.
    func markDone(batch targets: [Target]) async {
        guard !targets.isEmpty else { return }
        try? await store.markDone(uids: targets.map(\.uid))
        await writeThrough(targets, capability: .markDone) { connector, target in
            try await connector.markDone(
                externalID: target.externalID, payload: target.payload)
        }
    }

    func completeTask(batch targets: [Target]) async {
        guard !targets.isEmpty else { return }
        try? await store.markDone(
            uids: targets.map(\.uid), reason: Store.DoneReason.completed)
        await writeThrough(targets, capability: .completesTask) {
            connector, target in
            try await connector.complete(
                externalID: target.externalID, payload: target.payload)
        }
    }

    func snooze(batch targets: [Target], until: Date) async {
        guard !targets.isEmpty else { return }
        try? await store.snooze(uids: targets.map(\.uid), until: until)
        await writeThrough(targets, capability: .remoteSnooze) {
            connector, target in
            try await connector.snooze(
                externalID: target.externalID, until: until,
                payload: target.payload)
        }
    }

    /// One ⌘Z over a batch, honouring what each row was done *for*.
    ///
    /// The store reports the reason per uid, so a mixed topic un-completes
    /// its Reminders member in Reminders while leaving the dismissed Slack
    /// member alone — the same rule the single-row path already follows,
    /// applied per member rather than to the batch as a whole.
    func undoDone(batch targets: [Target]) async {
        guard !targets.isEmpty else { return }
        let reasons =
            (try? await store.undoDone(uids: targets.map(\.uid))) ?? [:]
        let completed = targets.filter {
            reasons[$0.uid] == Store.DoneReason.completed
                && !$0.externalID.isEmpty
        }
        await writeThrough(completed, capability: .completesTask) {
            connector, target in
            try await connector.uncomplete(
                externalID: target.externalID, payload: target.payload)
        }
        // Rows that were merely dismissed still moved, so the queue has to
        // hear about it even when nothing was written anywhere.
        if completed.isEmpty { notify(sourceID: "") }
    }

    /// Runs one write-through per target, grouped so each source's outcome is
    /// reported against that source.
    private func writeThrough(
        _ targets: [Target], capability: ConnectorCapabilities,
        _ body: (any Connector, Target) async throws -> Void
    ) async {
        var failures: [String: String] = [:]
        var touched: [String] = []
        for target in targets {
            if !touched.contains(target.sourceID) {
                touched.append(target.sourceID)
            }
            guard let connector = connectors[target.sourceID],
                connector.capabilities.contains(capability)
            else { continue }
            do {
                try await body(connector, target)
            } catch {
                failures[target.sourceID] = String(describing: error)
            }
        }
        for sourceID in touched {
            notify(sourceID: sourceID, writeThroughFailure: failures[sourceID])
        }
    }

    func markDone(uid: String, sourceID: String, externalID: String, payload: Data?) async {
        try? await store.markDone(uid: uid)
        var failure: String?
        if let connector = connectors[sourceID],
            connector.capabilities.contains(.markDone) {
            do {
                try await connector.markDone(externalID: externalID, payload: payload)
            } catch {
                failure = String(describing: error)
            }
        }
        notify(sourceID: sourceID, writeThroughFailure: failure)
    }

    /// Finishes a to-do in its source, and marks the row done locally.
    ///
    /// Mirrors `markDone` deliberately, including the order: the local write
    /// lands first so the queue responds to the keypress immediately, and a
    /// write-through failure is *named* rather than swallowed. Silence here
    /// would be the worst of both — the row leaves the queue while the task
    /// stays open in Reminders, and nothing says so (rule 5).
    func completeTask(
        uid: String, sourceID: String, externalID: String, payload: Data?
    ) async {
        try? await store.markDone(uid: uid, reason: Store.DoneReason.completed)
        var failure: String?
        if let connector = connectors[sourceID],
            connector.capabilities.contains(.completesTask) {
            do {
                try await connector.complete(externalID: externalID, payload: payload)
            } catch {
                failure = String(describing: error)
            }
        }
        notify(sourceID: sourceID, writeThroughFailure: failure)
    }

    /// Whether this source can complete tasks — the panel and the main window
    /// both need to know before offering `C`.
    func completesTasks(sourceID: String) async -> Bool {
        connectors[sourceID]?.capabilities.contains(.completesTask) ?? false
    }

    /// Brings a done item back — and reopens the task in its source when the
    /// done was a *completion* rather than a dismissal.
    ///
    /// The store reports which kind of done it was, because by the time undo
    /// runs nothing else knows. Without this branch, ⌘Z after `C` would put the
    /// row back while leaving the reminder ticked off in Reminders.
    func undoDone(
        uid: String, sourceID: String, externalID: String = "", payload: Data? = nil
    ) async {
        let reason = try? await store.undoDone(uid: uid)
        var failure: String?
        if reason == Store.DoneReason.completed, !externalID.isEmpty,
            let connector = connectors[sourceID],
            connector.capabilities.contains(.completesTask) {
            do {
                try await connector.uncomplete(
                    externalID: externalID, payload: payload)
            } catch {
                failure = String(describing: error)
            }
        }
        notify(sourceID: sourceID, writeThroughFailure: failure)
    }

    func snooze(uid: String, sourceID: String, externalID: String, until: Date, payload: Data?) async {
        try? await store.snooze(uid: uid, until: until)
        var failure: String?
        if let connector = connectors[sourceID],
            connector.capabilities.contains(.remoteSnooze) {
            do {
                try await connector.snooze(externalID: externalID, until: until, payload: payload)
            } catch {
                failure = String(describing: error)
            }
        }
        notify(sourceID: sourceID, writeThroughFailure: failure)
    }

    // MARK: Context

    /// Rich detail for an expanded row. Answers `.unavailable` for sources
    /// that never provide context (or are gone) so the panel shows nothing
    /// rather than a spinner that can't resolve; a connector error becomes
    /// `.failed` with its description, rendered inline where the user is
    /// looking (rule 5).
    func fetchContext(
        sourceID: String, externalID: String, payload: Data?
    ) async -> ContextFetch {
        guard let connector = connectors[sourceID],
            connector.capabilities.contains(.providesContext)
        else { return .unavailable }
        do {
            guard
                let context = try await connector.context(
                    externalID: externalID, payload: payload),
                !context.isEmpty
            else { return .unavailable }
            return .context(context)
        } catch {
            return .failed(String(describing: error))
        }
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
            let interval = connector.pollInterval
            while !Task.isCancelled {
                await pollOnce(connector, sourceID: id)
                try? await Task.sleep(for: .seconds(interval + .random(in: 0...5)))
            }
        }
    }

    private func pollOnce(_ connector: any Connector, sourceID: String) async {
        do {
            let snapshot = try await connector.fetch()
            // A truncated snapshot can't stand in for the whole remote queue,
            // so remote-truth archiving is suspended for this cycle rather
            // than archiving everything we simply didn't fetch.
            let complete = await connector.snapshotWasComplete()
            let result = try await store.reconcile(
                snapshot: snapshot, sourceID: sourceID,
                sourceKind: connector.sourceKind,
                remoteTruth: (remoteTruth[sourceID] ?? false) && complete,
                announcesReturn: announcesReturn[sourceID] ?? false)
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
                remoteTruth: remoteTruth[sourceID] ?? false,
                announcesReturn: announcesReturn[sourceID] ?? false)
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

    /// A write-through failure must not stay silent. The local store has
    /// already recorded the item as done/snoozed, but the service still shows
    /// it unread — without a status the two drift apart invisibly, which is
    /// exactly what a triage queue must never do (PLAN §2). Surfacing it puts
    /// the source's footer dot into its error state with the reason.
    private func notify(sourceID: String, writeThroughFailure: String? = nil) {
        onChange(
            QueueChange(
                sourceID: sourceID, inserted: [], snoozeWakes: [],
                status: writeThroughFailure.map { .error($0) }))
    }
}
