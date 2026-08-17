import Foundation
import KeyboardShortcuts
import SwiftData
import SwiftUI
import UserNotifications

extension KeyboardShortcuts.Name {
    /// ⌥⌘I by default (decision §2.1.11), customizable in Settings.
    static let togglePanel = Self(
        "togglePanel", default: .init(.i, modifiers: [.command, .option]))
}

/// MainActor hub: owns the model container, store, engine; derives badge;
/// dispatches banners; holds the undo-done stack and UI state.
@MainActor
@Observable
final class AppState {
    let container: ModelContainer
    let store: Store
    private(set) var engine: SyncEngine!

    /// Bumped whenever the queue changes so views can re-query.
    var queueVersion = 0
    var badgeText: String?
    var statuses: [String: ConnectorStatus] = [:]
    /// uids of user-done items, most recent last (⌘Z pops).
    var undoStack: [String] = []
    var selectedSourceFilter: String?  // nil = All

    var badgeStyle: BadgeStyle {
        get {
            BadgeStyle(
                rawValue: UserDefaults.standard.string(forKey: "badgeStyle")
                    ?? "") ?? .highSignalCount
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "badgeStyle")
            Task { await refreshBadge() }
        }
    }

    init() {
        do {
            let url = URL.applicationSupportDirectory
                .appending(path: "InboxAndChill/store.sqlite")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            container = try ModelContainer(
                for: Item.self, SourceConfig.self,
                configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Cannot open store: \(error)")
        }
        store = Store(modelContainer: container)
        engine = SyncEngine(store: store) { [weak self] change in
            Task { @MainActor in self?.handle(change) }
        }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
        Task { await bootstrapConnectors() }
    }

    // MARK: Connector bootstrap

    func bootstrapConnectors() async {
        let configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        for config in configs where config.isEnabled {
            if let connector = ConnectorFactory.make(config: config) {
                await engine.register(connector)
            }
        }
        #if DEBUG
            if configs.isEmpty,
                ProcessInfo.processInfo.environment["INCHILL_NO_FAKE"] == nil {
                await engine.register(FakeConnector())
            }
        #endif
    }

    // MARK: Queue change handling

    private func handle(_ change: QueueChange) {
        queueVersion += 1
        if let status = change.status, !change.sourceID.isEmpty {
            statuses[change.sourceID] = status
        }
        // Banners: opt-in per source for new items; snooze wakes always.
        let bannerSources = bannerEnabledSourceIDs()
        let bannerItems =
            change.inserted.filter { bannerSources.contains($0.sourceID) }
            + change.snoozeWakes
        for item in bannerItems {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: item.id, content: content, trigger: nil))
        }
        Task { await refreshBadge() }
    }

    func refreshBadge() async {
        let style = badgeStyle
        guard style != .none else {
            badgeText = nil
            return
        }
        let counted = countedSourceIDs()
        let counts =
            (try? await store.badgeCounts(countedSourceIDs: counted))
            ?? (0, 0)
        let n = style == .totalCount ? counts.0 : counts.1
        switch style {
        case .dot: badgeText = n > 0 ? "●" : nil
        case .none: badgeText = nil
        default: badgeText = n > 0 ? "\(n)" : nil
        }
    }

    // MARK: Triage actions (called from UI)

    func open(_ item: Item) {
        if let url = item.url { NSWorkspace.shared.open(url) }
        // Open ≠ done (decision §2.1.2).
    }

    func markDone(_ item: Item) {
        undoStack.append(item.uid)
        let (uid, sourceID, ext, payload) =
            (item.uid, item.sourceID, externalID(of: item), item.payload)
        Task {
            await engine.markDone(
                uid: uid, sourceID: sourceID, externalID: ext, payload: payload)
        }
    }

    func undoDone() {
        guard let uid = undoStack.popLast() else { return }
        Task {
            let sourceID = String(uid.split(separator: ":").first ?? "")
            await engine.undoDone(uid: uid, sourceID: sourceID)
        }
    }

    func snooze(_ item: Item, until: Date) {
        let (uid, sourceID, ext, payload) =
            (item.uid, item.sourceID, externalID(of: item), item.payload)
        Task {
            await engine.snooze(
                uid: uid, sourceID: sourceID, externalID: ext, until: until,
                payload: payload)
        }
    }

    func togglePin(_ item: Item) {
        let uid = item.uid
        Task {
            try? await store.togglePin(uid: uid)
            await MainActor.run { queueVersion += 1 }
            await refreshBadge()
        }
    }

    // MARK: Helpers

    private func externalID(of item: Item) -> String {
        String(item.uid.dropFirst(item.sourceKind.count + 1))
    }

    private func bannerEnabledSourceIDs() -> Set<String> {
        let configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        return Set(configs.filter(\.bannersEnabled).map(\.id))
    }

    private func countedSourceIDs() -> Set<String> {
        let configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        var ids = Set(configs.filter(\.countsTowardBadge).map(\.id))
        #if DEBUG
            ids.insert("fake-1")
        #endif
        return ids
    }
}

/// Builds a connector from a stored config. Real kinds land in M1–M4.
enum ConnectorFactory {
    static func make(config: SourceConfig) -> (any Connector)? {
        switch config.kind {
        case "fake": return FakeConnector(sourceID: config.id)
        default: return nil
        }
    }
}
