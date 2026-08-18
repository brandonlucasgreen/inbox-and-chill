import Foundation
import KeyboardShortcuts
import ServiceManagement
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
    var launchAtLoginError: String?

    /// Persisted across relaunch (§5.3). nil = All.
    var selectedSourceFilter: String? {
        get {
            access(keyPath: \.selectedSourceFilter)
            return UserDefaults.standard.string(forKey: "panel.sourceFilter")
        }
        set {
            withMutation(keyPath: \.selectedSourceFilter) {
                UserDefaults.standard.set(
                    newValue, forKey: "panel.sourceFilter")
            }
        }
    }

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
            }
        }
    }

    var badgeStyle: BadgeStyle {
        get {
            access(keyPath: \.badgeStyle)
            return BadgeStyle(
                rawValue: UserDefaults.standard.string(forKey: "badgeStyle")
                    ?? "") ?? .highSignalCount
        }
        set {
            withMutation(keyPath: \.badgeStyle) {
                UserDefaults.standard.set(
                    newValue.rawValue, forKey: "badgeStyle")
            }
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
        // Permission is requested lazily, right before the first banner —
        // not at launch (banners are opt-in; don't alert before the UI).
        notificationDelegate = NotificationDelegate(appState: self)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task {
            await bootstrapConnectors()
            await refreshBadge()
        }
    }

    private var notificationDelegate: NotificationDelegate?

    /// Banner sound is off by default (§2.1.4: silent posture).
    var bannerSound: Bool {
        get {
            access(keyPath: \.bannerSound)
            return UserDefaults.standard.bool(forKey: "bannerSound")
        }
        set {
            withMutation(keyPath: \.bannerSound) {
                UserDefaults.standard.set(newValue, forKey: "bannerSound")
            }
        }
    }

    // MARK: Journal (Sources/App/Journal/JournalWriter.swift)

    /// Off by default, and with no default path: the useful value is a
    /// personal vault location that only the user can supply.
    var journalEnabled: Bool {
        get {
            access(keyPath: \.journalEnabled)
            return UserDefaults.standard.bool(forKey: "journalEnabled")
        }
        set {
            withMutation(keyPath: \.journalEnabled) {
                UserDefaults.standard.set(newValue, forKey: "journalEnabled")
            }
        }
    }

    var journalPath: String {
        get {
            access(keyPath: \.journalPath)
            return UserDefaults.standard.string(forKey: "journalPath") ?? ""
        }
        set {
            withMutation(keyPath: \.journalPath) {
                UserDefaults.standard.set(newValue, forKey: "journalPath")
            }
        }
    }

    var journalHeading: String {
        get {
            access(keyPath: \.journalHeading)
            let stored = UserDefaults.standard.string(forKey: "journalHeading")
            return (stored?.isEmpty == false) ? stored! : "## Inbox & Chill"
        }
        set {
            withMutation(keyPath: \.journalHeading) {
                UserDefaults.standard.set(newValue, forKey: "journalHeading")
            }
        }
    }

    /// The two halves of Brandon's ask: log what arrives, and log what you
    /// did about it. Either can be turned off independently.
    var journalLogArrivals: Bool {
        get {
            access(keyPath: \.journalLogArrivals)
            return UserDefaults.standard.object(forKey: "journalLogArrivals")
                as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.journalLogArrivals) {
                UserDefaults.standard.set(newValue, forKey: "journalLogArrivals")
            }
        }
    }

    var journalLogActions: Bool {
        get {
            access(keyPath: \.journalLogActions)
            return UserDefaults.standard.object(forKey: "journalLogActions")
                as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.journalLogActions) {
                UserDefaults.standard.set(newValue, forKey: "journalLogActions")
            }
        }
    }

    /// Last write failure, surfaced in Settings. Writing to a vault under
    /// ~/Documents needs a one-time macOS Files-and-Folders grant, and a
    /// denial has to be visible rather than swallowed (the write-through bug
    /// taught us that once already).
    var journalError: String?

    private var journalConfig: JournalConfig {
        JournalConfig(pathTemplate: journalPath, heading: journalHeading)
    }

    /// Fire-and-forget, but never silent: failures land in `journalError`.
    private func journal(_ entries: [JournalEntry]) {
        guard journalEnabled, !entries.isEmpty else { return }
        let config = journalConfig
        Task {
            for entry in entries {
                do {
                    try await JournalWriter.shared.record(entry, config: config)
                } catch {
                    await MainActor.run {
                        self.journalError = String(describing: error)
                    }
                    return
                }
            }
            await MainActor.run { self.journalError = nil }
        }
    }

    private func journal(
        _ action: JournalAction, item: Item, detail: String? = nil
    ) {
        guard journalEnabled, journalLogActions else { return }
        journal([
            JournalEntry(
                at: .now, action: action,
                sourceName: sourceName(forID: item.sourceID),
                title: item.title, url: item.url?.absoluteString, detail: detail)
        ])
    }

    private func sourceName(forID sourceID: String) -> String {
        var descriptor = FetchDescriptor<SourceConfig>(
            predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        let config = try? container.mainContext.fetch(descriptor).first
        return config?.displayName ?? ""
    }

    // MARK: Connector bootstrap

    func bootstrapConnectors() async {
        var configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        // The local source (terminal + Claude Code) is built-in: create it on
        // first run. Banners default on for local (decision §2.1.4).
        if !configs.contains(where: { $0.kind == "local" }) {
            let local = SourceConfig(
                kind: "local", displayName: "Terminal & Claude Code",
                bannersEnabled: true)
            container.mainContext.insert(local)
            try? container.mainContext.save()
            configs.append(local)
        }
        for config in configs where config.isEnabled {
            if let connector = ConnectorFactory.make(config: config) {
                await engine.register(connector)
            }
        }
        #if DEBUG
            if configs.allSatisfy({ $0.kind == "local" }),
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
        if !bannerItems.isEmpty {
            let sound = bannerSound
            Task { await Self.postBanners(bannerItems, sound: sound) }
        }
        if journalEnabled, journalLogArrivals, !change.inserted.isEmpty {
            let name = sourceName(forID: change.sourceID)
            journal(
                change.inserted.map {
                    JournalEntry(
                        at: .now, action: .arrived, sourceName: name,
                        title: $0.title, url: $0.urlString, detail: nil)
                })
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

    /// Requests permission on first use (if undetermined), then posts.
    private static func postBanners(_ items: [ItemSummary], sound: Bool) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted =
                (try? await center.requestAuthorization(
                    options: [.alert, .sound])) ?? false
            guard granted else { return }
        case .denied:
            return
        default:
            break
        }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            if let snippet = item.snippet { content.body = snippet }
            content.subtitle = ConnectorCatalog.descriptor(
                for: item.sourceKind)?.displayName ?? item.sourceKind
            content.threadIdentifier = item.sourceID
            content.userInfo = ["uid": item.id]
            if sound { content.sound = .default }
            try? await center.add(
                UNNotificationRequest(
                    identifier: item.id, content: content, trigger: nil))
        }
    }

    /// Banner click → open the item's URL (or the panel as fallback).
    func handleNotificationTap(uid: String) {
        var descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1
        if let item = try? container.mainContext.fetch(descriptor).first,
            item.url != nil {
            open(item)
        } else {
            PanelToggler.toggle()
        }
    }

    // MARK: Triage actions (called from UI)

    func open(_ item: Item) {
        if let url = item.url { NSWorkspace.shared.open(url) }
        // Open ≠ done (decision §2.1.2).
    }

    func markDone(_ item: Item) {
        undoStack.append(item.uid)
        journal(
            .done, item: item,
            detail: JournalWriter.waited(from: item.firstSeenAt, to: .now))
        let (uid, sourceID, ext, payload) =
            (item.uid, item.sourceID, externalID(of: item), item.payload)
        Task {
            await engine.markDone(
                uid: uid, sourceID: sourceID, externalID: ext, payload: payload)
        }
    }

    func undoDone() {
        guard let uid = undoStack.popLast() else { return }
        restore(uid: uid)
    }

    /// Bring a done item back to the queue (⌘Z and archive Restore).
    func restore(uid: String) {
        if journalEnabled, journalLogActions, let item = item(forUID: uid) {
            journal(.restored, item: item)
        }
        undoStack.removeAll { $0 == uid }
        let sourceID = sourceID(forUID: uid)
        Task { await engine.undoDone(uid: uid, sourceID: sourceID) }
    }

    private func item(forUID uid: String) -> Item? {
        var descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1
        return try? container.mainContext.fetch(descriptor).first
    }

    /// Snooze targets are read by humans in a note, so this one is localised
    /// (unlike the journal's machine-stable `HH:mm` timestamp).
    private static let journalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func sourceID(forUID uid: String) -> String {
        var descriptor = FetchDescriptor<Item>(
            predicate: #Predicate { $0.uid == uid })
        descriptor.fetchLimit = 1
        return (try? container.mainContext.fetch(descriptor).first?.sourceID)
            ?? ""
    }

    func snooze(_ item: Item, until: Date) {
        journal(
            .snoozed, item: item,
            detail: "until \(Self.journalDateFormatter.string(from: until))")
        let (uid, sourceID, ext, payload) =
            (item.uid, item.sourceID, externalID(of: item), item.payload)
        Task {
            await engine.snooze(
                uid: uid, sourceID: sourceID, externalID: ext, until: until,
                payload: payload)
        }
    }

    func togglePin(_ item: Item) {
        // Read before the store flips it: this is the action we're about to
        // take, not the state we're leaving.
        journal(item.isPinned ? .unpinned : .pinned, item: item)
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

/// Routes banner clicks back into the app and shows banners while frontmost.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let uid =
            response.notification.request.content.userInfo["uid"] as? String
        completionHandler()
        guard let uid else { return }
        let state = appState  // @MainActor class — Sendable reference
        Task { @MainActor in
            state?.handleNotificationTap(uid: uid)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}

/// Builds a connector from a stored config.
enum ConnectorFactory {
    static func make(config: SourceConfig) -> (any Connector)? {
        let settings = config.settings
        switch config.kind {
        case "fake":
            return FakeConnector(sourceID: config.id)
        case "linear":
            return LinearConnector(
                sourceID: config.id,
                oauthClientID: settings["oauthClientID"])
        case "github":
            let field = ConnectorCatalog.descriptor(for: "github")?
                .fields.first { $0.key == "participating" }
            return GitHubConnector(
                sourceID: config.id,
                participating: field?.boolValue(in: settings) ?? true)
        case "local":
            return LocalConnector(sourceID: config.id)
        case "ntfy":
            return NtfyConnector(
                sourceID: config.id, server: settings["server"] ?? "",
                topics: settings["topics"] ?? "")
        case "jsonPoller":
            return JSONPollerConnector(
                sourceID: config.id, urlString: settings["url"] ?? "",
                mapping: settings["mapping"] ?? "")
        case "campsite":
            return CampsiteConnector(
                sourceID: config.id, baseURL: settings["baseURL"] ?? "",
                orgSlug: settings["orgSlug"] ?? "")
        case "slack":
            return SlackConnector(
                sourceID: config.id,
                saveEmoji: settings["saveEmoji"].flatMap {
                    $0.isEmpty ? nil : $0
                } ?? "pushpin")
        default:
            return nil
        }
    }
}
