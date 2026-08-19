import Foundation
import KeyboardShortcuts
import OSLog
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

    /// Why banners are or aren't reaching the user; `nil` until something has
    /// looked. Surfaced in Settings — a banner the user asked for and didn't
    /// get must never fail silently (PLAN §2).
    private(set) var bannerAuthorization: BannerAuthorization.Outcome?

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

    var badgeShowsTotal: Bool {
        get {
            access(keyPath: \.badgeShowsTotal)
            return Self.badgeDefault(forKey: "badge.showsTotal") { $0.showsTotal }
        }
        set {
            withMutation(keyPath: \.badgeShowsTotal) {
                UserDefaults.standard.set(newValue, forKey: "badge.showsTotal")
            }
            Task { await refreshBadge() }
        }
    }

    var badgeShowsHighSignal: Bool {
        get {
            access(keyPath: \.badgeShowsHighSignal)
            return Self.badgeDefault(forKey: "badge.showsHighSignal") {
                $0.showsHighSignal
            }
        }
        set {
            withMutation(keyPath: \.badgeShowsHighSignal) {
                UserDefaults.standard.set(
                    newValue, forKey: "badge.showsHighSignal")
            }
            Task { await refreshBadge() }
        }
    }

    var badge: MenuBarBadge {
        MenuBarBadge(
            showsTotal: badgeShowsTotal, showsHighSignal: badgeShowsHighSignal)
    }

    /// Reads one of the two badge switches, falling back to whatever the old
    /// single-choice `badgeStyle` setting meant.
    ///
    /// The badge used to be one picker (high-signal / total / dot / off); it is
    /// now two independent toggles. Anyone upgrading has a `badgeStyle` string
    /// and none of the new keys, and silently defaulting them to "both on"
    /// would switch the badge back on for someone who had deliberately turned
    /// it off.
    private static func badgeDefault(
        forKey key: String, _ field: (MenuBarBadge) -> Bool
    ) -> Bool {
        if let stored = UserDefaults.standard.object(forKey: key) as? Bool {
            return stored
        }
        switch UserDefaults.standard.string(forKey: "badgeStyle") {
        case "totalCount":
            return field(MenuBarBadge(showsTotal: true, showsHighSignal: false))
        case "highSignalCount", "dot":
            return field(MenuBarBadge(showsTotal: false, showsHighSignal: true))
        case "none":
            return field(MenuBarBadge(showsTotal: false, showsHighSignal: false))
        default:
            return field(.default)
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
            // Read-only: a blocked permission shows up in Settings before an
            // item arrives, but nobody gets a system prompt they didn't ask for.
            await resolveBannerAuthorization(prompting: false)
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
            Task { await self.postBanners(bannerItems, sound: sound) }
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
        let badge = badge
        guard badge.showsTotal || badge.showsHighSignal else {
            badgeText = nil
            return
        }
        let counted = countedSourceIDs()
        let counts =
            (try? await store.badgeCounts(countedSourceIDs: counted))
            ?? (0, 0)
        badgeText = badge.text(total: counts.0, highSignal: counts.1)
    }

    /// Resolves banner permission, recording whatever blocks it in
    /// `bannerAuthorization`, and reports whether a banner can be posted.
    ///
    /// `prompting: false` only *reads* the state. macOS shows the permission
    /// prompt exactly once per install, so who spends it matters: pass `true`
    /// only where the user has just done something they can connect the
    /// prompt to (enabling banners for a source, or the button in Settings).
    @discardableResult
    func resolveBannerAuthorization(prompting: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let outcome: BannerAuthorization.Outcome

        if let settled = BannerAuthorization.settledOutcome(status: status) {
            outcome = settled
        } else if !prompting {
            // .notDetermined: nothing has asked macOS yet, so no banner has
            // ever had a chance of arriving — which is not an error, but is
            // not something to keep quiet about either.
            outcome = .notRequested
        } else {
            do {
                let granted = try await center.requestAuthorization(
                    options: [.alert, .sound])
                outcome = BannerAuthorization.requestOutcome(
                    granted: granted, error: nil)
            } catch {
                // `try?` here was the bug: a request macOS refuses outright
                // left the user with no banner, no prompt, and nothing to go on.
                outcome = BannerAuthorization.requestOutcome(
                    granted: false, error: error.localizedDescription)
            }
        }

        // The raw status goes to the log as well as to Settings: a status
        // that isn't `.notDetermined` but has no Notification Center record
        // means macOS will never show the prompt, and the number is the only
        // way to tell that apart from an ordinary denial.
        Self.bannerLog.notice(
            """
            banner permission resolved: status=\(status.rawValue, privacy: .public) \
            prompted=\(prompting, privacy: .public) \
            outcome=\(String(describing: outcome), privacy: .public)
            """)

        bannerAuthorization = outcome
        return outcome == .granted
    }

    /// Banner delivery is the one path the app cannot verify for itself —
    /// macOS accepts the posting call and drops it — so the resolved
    /// permission state is recorded where it can be read after the fact.
    private static let bannerLog = Logger(
        subsystem: "lol.bgreen.inboxandchill", category: "banners")

    /// Requests permission on first use (if undetermined), then posts.
    private func postBanners(_ items: [ItemSummary], sound: Bool) async {
        guard await resolveBannerAuthorization(prompting: true) else { return }
        let center = UNUserNotificationCenter.current()
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            if let snippet = item.snippet { content.body = snippet }
            content.subtitle = ConnectorCatalog.descriptor(
                for: item.sourceKind)?.displayName ?? item.sourceKind
            content.threadIdentifier = item.sourceID
            content.userInfo = ["uid": item.id]
            if sound { content.sound = .default }
            do {
                try await center.add(
                    UNNotificationRequest(
                        identifier: item.id, content: content, trigger: nil))
            } catch {
                // Permission granted is not the same as banner delivered.
                // One failure explains the batch; the rest fail identically.
                bannerAuthorization = BannerAuthorization.postFailure(
                    error.localizedDescription)
                return
            }
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
        guard let url = item.url else { return }
        NSWorkspace.shared.open(Self.openable(url, payload: item.payload))
        // Open ≠ done (decision §2.1.2).
    }

    /// Which of an item's links to actually open.
    ///
    /// Slack rows carry a `slack://` deep link so they land in the Slack app
    /// rather than bouncing through a browser. That link is dead on a Mac
    /// without Slack installed, so the https permalink rides along in the
    /// payload and is used instead when nothing handles the scheme.
    static func openable(_ url: URL, payload: Data?) -> URL {
        guard url.scheme == "slack", !handlesSlackScheme() else { return url }
        guard let payload,
            let fallback = SlackConnector.permalink(in: payload),
            let web = URL(string: fallback)
        else { return url }
        return web
    }

    /// Cached: it's a Launch Services round trip, and the answer only
    /// changes if the user installs or removes Slack mid-session.
    private static let slackSchemeHandled: Bool = {
        guard let probe = URL(string: "slack://channel") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }()

    private static func handlesSlackScheme() -> Bool { slackSchemeHandled }

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

    /// Records that the user has focused a row, clearing its unseen dot.
    ///
    /// Fire-and-forget and cheap to over-call: the store ignores an item that
    /// already carries a stamp, so selection changes can call this freely.
    func markSeen(_ item: Item) {
        guard !item.isSeen else { return }
        let uid = item.uid
        Task {
            guard (try? await store.markSeen(uid: uid)) == true else { return }
            await MainActor.run { queueVersion += 1 }
        }
    }

    /// Flips the selected item between read and unread (`U`).
    func toggleSeen(_ item: Item) {
        let uid = item.uid
        Task {
            _ = try? await store.toggleSeen(uid: uid)
            await MainActor.run { queueVersion += 1 }
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

    /// Whether any source is set to banner at all.
    var hasBannerEnabledSource: Bool { !bannerEnabledSourceIDs().isEmpty }

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

/// Why banners are or aren't reaching the user, in the words Settings shows.
///
/// Deliberately free of `UNUserNotificationCenter`: the wording is the part
/// that has to be right, and a test process can't stand up the notification
/// system to exercise it. `UNAuthorizationStatus` is a plain enum, so the
/// mapping stays testable while the I/O it describes lives in `AppState`.
enum BannerAuthorization {
    enum Outcome: Equatable {
        /// macOS will deliver banners.
        case granted
        /// Nothing has asked macOS yet, so no banner can arrive. Not an
        /// error — but not silence either: the user gets a button to ask.
        case notRequested
        /// Asked and refused, with the reason to show.
        case blocked(String)

        /// The red-text message, or `nil` when there's nothing wrong to say.
        var message: String? {
            if case .blocked(let message) = self { return message }
            return nil
        }
    }

    /// The verdict for an already-settled status, or `nil` for
    /// `.notDetermined` — the one case where asking macOS is still on the
    /// table, and only the caller knows whether this is the moment for it.
    static func settledOutcome(status: UNAuthorizationStatus) -> Outcome? {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .blocked(deniedMessage)
        case .notDetermined:
            return nil
        @unknown default:
            // An unrecognised status is not a licence to assume delivery.
            return .blocked(
                "macOS reported a notification permission state Inbox & Chill doesn't recognise, so banners may not be delivered."
            )
        }
    }

    /// The verdict once `requestAuthorization` has answered.
    static func requestOutcome(granted: Bool, error: String?) -> Outcome {
        if let error, !error.isEmpty {
            return .blocked(
                "macOS refused the notification permission request, so no banners can be shown: \(error)"
            )
        }
        return granted ? .granted : .blocked(declinedMessage)
    }

    /// A banner macOS had permission for but still wouldn't take.
    static func postFailure(_ error: String) -> Outcome {
        .blocked("macOS rejected a banner: \(error)")
    }

    static let deniedMessage =
        "Notifications from Inbox & Chill are turned off in macOS, so no banners can be shown. Turn “Allow notifications” back on in System Settings › Notifications › Inbox & Chill."

    static let declinedMessage =
        "Notification permission was declined, so no banners can be shown. You can turn it on in System Settings › Notifications › Inbox & Chill."

    /// Deep link to System Settings › Notifications.
    static let systemSettingsURL = URL(
        string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!
}

/// Builds a connector from a stored config.
enum ConnectorFactory {
    static func make(config: SourceConfig) -> (any Connector)? {
        let settings = config.settings
        switch config.kind {
        case "fake":
            return FakeConnector(sourceID: config.id)
        case "linear":
            return LinearConnector(sourceID: config.id)
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
                topics: settings["topics"] ?? "",
                username: settings["username"] ?? "")
        case "jsonPoller":
            return JSONPollerConnector(
                sourceID: config.id, urlString: settings["url"] ?? "",
                mapping: settings["mapping"] ?? "")
        case "slack":
            return SlackConnector(
                sourceID: config.id,
                saveEmoji: settings["saveEmoji"].flatMap {
                    $0.isEmpty ? nil : $0
                } ?? "pushpin",
                searchTerms: settings["searchTerms"] ?? "",
                mutedChannels: settings["mutedChannels"] ?? "")
        default:
            return nil
        }
    }
}
