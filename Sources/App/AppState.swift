import Foundation
import OSLog
import ServiceManagement
import SwiftData
import SwiftUI
import UserNotifications

/// MainActor hub: owns the model container, store, engine; derives badge;
/// dispatches banners; holds the undo-done stack and UI state.
@MainActor
@Observable
final class AppState {
    let container: ModelContainer
    let store: Store
    let license: LicenseController
    private(set) var engine: SyncEngine!

    /// Bumped whenever the queue changes so views can re-query.
    var queueVersion = 0
    var badgeText: String?
    var statuses: [String: ConnectorStatus] = [:]
    /// uids of user-done items, most recent last (⌘Z pops).
    /// ⌘Z history, one **entry** per user action rather than one per row.
    ///
    /// Dismissing a topic is one gesture and has to be one undo, so an entry
    /// is a list of uids. It was a flat `[String]` while every action touched
    /// exactly one row; a multi-selection in the main window has always
    /// pushed one entry per item, which meant undoing a five-row dismissal
    /// took five ⌘Z. That is fixed by the same change.
    var undoStack: [[String]] = []
    var launchAtLoginError: String?

    /// Why the last ⏎ landed somewhere other than where the item pointed.
    /// nil in the ordinary case, including the ordinary *fallbacks* — a
    /// session whose window has closed is not a problem to nag about. Set
    /// only when the user could do something about it (see
    /// `ClaudeSessionTarget.explain`).
    var openProblem: String?

    /// Why banners are or aren't reaching the user; `nil` until something has
    /// looked. Surfaced in Settings — a banner the user asked for and didn't
    /// get must never fail silently (PLAN §2).
    private(set) var bannerAuthorization: BannerAuthorization.Outcome?

    /// Whether macOS will let the app read Mail; `nil` until something has
    /// looked. Same contract as `bannerAuthorization` and for the same
    /// reason — a refusal here is invisible from the queue, because it looks
    /// exactly like an inbox with nothing in it.
    private(set) var mailAutomation: MailAutomationAuthorization.Outcome?
    private(set) var remindersAccess: RemindersAuthorization.Outcome?

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
                    ProblemLog.note(
                        .launchAtLogin,
                        "Couldn't \(newValue ? "turn on" : "turn off") "
                            + "Launch at login: \(error.localizedDescription)",
                        detail: String(describing: error))
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
                for: Item.self, SourceConfig.self, Topic.self,
                configurations: ModelConfiguration(url: url))
        } catch {
            fatalError("Cannot open store: \(error)")
        }
        store = Store(modelContainer: container)
        license = LicenseController()
        engine = SyncEngine(store: store) { [weak self] change in
            Task { @MainActor in self?.handle(change) }
        }
        // Trial expiry and activation both land mid-run — a menu bar app
        // lives for weeks, so launch-time gating alone would keep syncing
        // for days past the end of a trial.
        license.onSyncPermissionChange = { [weak self] allowed in
            guard let self else { return }
            Task { @MainActor in
                if allowed {
                    await self.bootstrapConnectors()
                    await self.engine.refreshNow()
                } else {
                    await self.engine.unregisterAll()
                }
            }
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
                    ProblemLog.note(
                        .journal,
                        "Couldn't write the journal: \(error.localizedDescription)",
                        detail: String(describing: error))
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

    /// The batch form, carrying the same `journalLogActions` guard.
    ///
    /// One line per item, not one per gesture: the journal is a record of
    /// notifications, and folding four of them into "dismissed a topic" would
    /// lose the four things that were actually dealt with.
    private func journal(
        _ action: JournalAction, items: [Item],
        detail: (Item) -> String? = { _ in nil }
    ) {
        guard journalEnabled, journalLogActions else { return }
        journal(
            items.map { item in
                JournalEntry(
                    at: .now, action: action,
                    sourceName: sourceName(forID: item.sourceID),
                    title: item.title, url: item.url?.absoluteString,
                    detail: detail(item))
            })
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
        // An ended trial pauses syncing — loudly, in the panel and Settings
        // (`LicenseNotice`) — and gates nothing else: the queue, the archive
        // and every triage action keep working on what's already here.
        guard license.state.allowsSync else { return }
        var configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        // The local source (terminal + Claude Code) is built-in: create it on
        // first run. Banners default on for local (decision §2.1.4).
        if Self.shouldCreateLocalSource(
            hasLocalConfig: configs.contains(where: { $0.kind == "local" }),
            userRemoved: Self.localSourceUserRemoved)
        {
            let local = SourceConfig(
                kind: "local", displayName: "Terminal & Claude Code",
                bannersEnabled: true)
            container.mainContext.insert(local)
            try? container.mainContext.save()
            configs.append(local)
        }
        ensureClaudeCodeHooks(configs: configs)
        var taskSourceIDs: Set<String> = []
        for config in configs where config.isEnabled {
            if let connector = ConnectorFactory.make(config: config) {
                // Read off the connector rather than restating it in the
                // catalog: the capability is the truth, and a second
                // declaration is a second thing to get out of step.
                if connector.capabilities.contains(.completesTask) {
                    taskSourceIDs.insert(connector.sourceID)
                }
                await engine.register(connector)
            }
        }
        completesTaskSourceIDs = taskSourceIDs
        #if DEBUG
            if configs.allSatisfy({ $0.kind == "local" }),
                ProcessInfo.processInfo.environment["INCHILL_NO_FAKE"] == nil {
                await engine.register(FakeConnector())
            }
        #endif
    }

    /// Whether `bootstrapConnectors()` should (re)create the built-in local
    /// source. Pulled out as a pure function per rule 6 — the SwiftData
    /// plumbing around it isn't worth testing, this decision is.
    nonisolated static func shouldCreateLocalSource(
        hasLocalConfig: Bool, userRemoved: Bool
    ) -> Bool {
        !hasLocalConfig && !userRemoved
    }

    private static let localSourceUserRemovedKey = "localSource.userRemoved"

    /// Set when the user deletes the local source from Settings → Sources.
    /// Without this, `bootstrapConnectors()` — which runs after every source
    /// add/edit/toggle, and on every launch — would recreate the source it
    /// was just told to remove, making the trash button in `SourcesPane` a
    /// no-op for this one row.
    static var localSourceUserRemoved: Bool {
        get { UserDefaults.standard.bool(forKey: localSourceUserRemovedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: localSourceUserRemovedKey)
        }
    }

    /// Why the app couldn't write an agent's hooks, keyed by harness id.
    /// Surfaced in Sources and in the local source's editor.
    private(set) var hookProblems: [String: String] = [:]

    /// Back-compat accessor for the Claude Code row.
    var claudeHooksProblem: String? { hookProblems["claude"] }

    /// Writes the Claude Code hooks on the app's own initiative.
    ///
    /// The local source is created on first run, and a source that can
    /// receive nothing until you find a button is a setup step masquerading
    /// as a feature — every other app that watches Claude Code (Vibe Island,
    /// Bartender's NotchBar) installs its hooks without asking, which is why
    /// theirs feel like they just work. So this does the same.
    ///
    /// Two things keep that honest rather than presumptuous: pressing Remove
    /// sets `userDeclinedHooks` and is never silently undone, and a failure
    /// is reported instead of leaving a source that quietly receives nothing.
    private func ensureClaudeCodeHooks(configs: [SourceConfig]) {
        let hasLocal = configs.contains { $0.kind == "local" && $0.isEnabled }
        // Every agent CLI the user actually has. A harness with no config
        // directory is skipped entirely rather than reported as unconfigured
        // — the app must not create `~/.codex` for someone who has never run
        // Codex.
        for installer in AgentHooks.all {
            ensureHooks(installer, hasEnabledLocalSource: hasLocal)
        }
    }

    private func ensureHooks(
        _ installer: AgentHookInstaller, hasEnabledLocalSource: Bool
    ) {
        let state = installer.installState
        let declined = installer.userDeclined
        let present = installer.isPresent
        // The app editing a file it does not own is worth a log line saying
        // exactly why it decided to.
        Self.hooksLog.notice(
            """
            \(installer.id, privacy: .public) hooks check: \
            state=\(String(describing: state), privacy: .public) \
            declined=\(declined, privacy: .public) \
            present=\(present, privacy: .public) \
            localSource=\(hasEnabledLocalSource, privacy: .public)
            """)
        guard AgentHookInstaller.shouldAutoInstall(
            state: state, userDeclined: declined, harnessIsPresent: present,
            hasEnabledLocalSource: hasEnabledLocalSource)
        else {
            hookProblems[installer.id] = nil
            return
        }
        do {
            try installer.installHooks()
            hookProblems[installer.id] = nil
            Self.hooksLog.notice(
                "\(installer.id, privacy: .public) hooks installed automatically"
            )
        } catch {
            let problem = AgentHookInstaller.explainAutoInstallFailure(
                error, displayName: installer.displayName,
                settingsLabel: installer.settingsLabel)
            hookProblems[installer.id] = problem
            ProblemLog.note(
                .claudeHooks, problem, detail: String(describing: error))
            Self.hooksLog.error(
                "\(installer.id, privacy: .public) hook auto-install failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Clears the opt-out and installs, for the "Turn On" button.
    func enableHooks(_ installer: AgentHookInstaller) {
        installer.userDeclined = false
        let configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        let hasLocal = configs.contains { $0.kind == "local" && $0.isEnabled }
        ensureHooks(installer, hasEnabledLocalSource: hasLocal)
    }

    /// Removes the hooks and records that the user meant it.
    func disableHooks(_ installer: AgentHookInstaller) {
        do {
            try installer.uninstallHooks()
            installer.userDeclined = true
            hookProblems[installer.id] = nil
        } catch {
            let problem =
                "Couldn't remove the \(installer.displayName) hooks from \(installer.settingsLabel): \(String(describing: error))"
            hookProblems[installer.id] = problem
            ProblemLog.note(.claudeHooks, problem)
        }
    }

    private static let hooksLog = AppLog.logger(.claudeHooks)

    // MARK: Queue change handling

    private func handle(_ change: QueueChange) {
        queueVersion += 1
        if let status = change.status, !change.sourceID.isEmpty {
            statuses[change.sourceID] = status
            // Every connector failure arrives here as `.error` (SyncEngine
            // turns a thrown error into one), so this single tee covers all
            // of them — including Apple Mail's -1743, which is invisible by
            // nature. `ProblemLog` suppresses repeats, so a source failing
            // every poll writes one line, not one per poll.
            if case .error(let message) = status {
                ProblemLog.note(
                    .sync, message,
                    sourceID: change.sourceID,
                    sourceLabel: sourceName(forID: change.sourceID))
            }
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
    private static let bannerLog = AppLog.logger(.banners)

    /// Resolves permission to read Mail, recording the outcome in
    /// `mailAutomation`, and reports whether a read can go ahead.
    ///
    /// `prompting: false` only reads the state and never shows a dialog, so
    /// it is safe on appear, on refresh, anywhere. Pass `true` **only** from
    /// a control the user just pressed: macOS shows the Automation dialog
    /// once, and the whole point of this flow is that the user has read what
    /// it is for before it appears (`MailAutomationAuthorization.preflight`).
    @discardableResult
    func resolveMailAutomation(prompting: Bool) async -> Bool {
        let previous = mailAutomation
        let outcome = await MailAutomation.resolve(prompting: prompting)
        mailAutomation = outcome
        // Only on the transition *into* granted. Permission just arrived, so
        // the sources that were refusing to poll have something to say now,
        // and without this the user waits out a poll interval after clicking
        // Allow — which reads as the permission not having worked. Firing on
        // every resolve instead would re-poll every source in the app each
        // time this view merely appeared.
        if outcome.allowsFetch, previous?.allowsFetch != true {
            await engine.refreshNow()
        }
        return outcome.allowsFetch
    }

    /// Resolves permission to read Reminders, recording the outcome in
    /// `remindersAccess`, and reports whether a read can go ahead.
    ///
    /// Same contract as `resolveMailAutomation`, for the same reason:
    /// `prompting: false` is free and shows nothing, so it is safe on appear
    /// and on refresh. Pass `true` **only** from a control the user just
    /// pressed — macOS shows its Reminders dialog once, and the point of the
    /// flow is that they have read `RemindersAuthorization.preflight` before
    /// it appears.
    @discardableResult
    func resolveRemindersAccess(prompting: Bool) async -> Bool {
        let previous = remindersAccess
        let outcome = await RemindersAccess.resolve(prompting: prompting)
        remindersAccess = outcome
        // Only on the transition into granted — otherwise the user waits out a
        // poll interval after clicking Allow, which reads as the permission
        // not having worked.
        if outcome.allowsFetch, previous?.allowsFetch != true {
            await engine.refreshNow()
        }
        return outcome.allowsFetch
    }

    /// Whether any configured, enabled source needs Reminders.
    var hasEnabledRemindersSource: Bool {
        let configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        return configs.contains { $0.kind == "reminders" && $0.isEnabled }
    }

    /// The reminder lists on this Mac, for the source editor's picker.
    ///
    /// Empty until access is granted, which is why the editor shows the
    /// permission control above the picker rather than beside it — an empty
    /// list of lists otherwise reads as "you have no reminders".
    func remindersListNames() -> [String] { RemindersAccess.listTitles() }

    /// Whether any configured, enabled source actually needs Mail — the
    /// notice is silent otherwise, exactly like `hasBannerEnabledSource`.
    var hasEnabledMailSource: Bool {
        let configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        return configs.contains { $0.kind == "appleMail" && $0.isEnabled }
    }

    /// Whether any enabled source depends on the Claude Code hooks. Same
    /// contract as `hasEnabledMailSource`: no local source, no notice.
    var hasEnabledLocalSource: Bool {
        let configs =
            (try? container.mainContext.fetch(FetchDescriptor<SourceConfig>()))
            ?? []
        return configs.contains { $0.kind == "local" && $0.isEnabled }
    }

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
        // A Claude Code item wants to land in the session that posted it, not
        // in the folder that session happens to be working in. `reveal`
        // returns `.fallBack` whenever it can't get there — including when it
        // has nothing to say about why — so the URL below stays the floor.
        if item.sourceKind == "local", item.kind.hasPrefix("claude") {
            switch ClaudeSessionOpener.reveal(ClaudeSessionTarget.target(payload: item.payload)) {
            case .reached:
                openProblem = nil
                return
            case .fallBack(let problem):
                openProblem = problem
            }
        }
        guard let url = item.url else { return }
        // A remote source can put any string in a row's URL: ntfy topics
        // are public by default, and a JSON feed is whatever its publisher
        // serves. `NSWorkspace.open` honours every registered handler, so
        // `shortcuts://run-shortcut?…` would run a Shortcut and
        // `file:///Applications/…` would launch an app. `openable` is the
        // gate — only http/https and the deep-links this app itself emits
        // reach Launch Services, and `file://`/`claude://` are local-source-
        // only. A refused scheme is named here rather than silently dropped
        // (rule 5): a row that won't open is the project's recurring bug
        // class, and "nothing happened" is the one outcome this must avoid.
        guard let resolved = Self.openable(
            url, sourceKind: item.sourceKind, payload: item.payload)
        else {
            openProblem = "Inbox & Chill won't open this link — its "
                + "\(url.scheme ?? "unknown") scheme isn't one the queue "
                + "trusts. The row may have come from a remote push; copy "
                + "the link if you know where it goes."
            return
        }
        NSWorkspace.shared.open(resolved)
        // Open ≠ done (decision §2.1.2).
    }

    /// Which of an item's links to actually open, or `nil` if the scheme
    /// isn't trusted enough to hand to `NSWorkspace.open`.
    ///
    /// Two jobs, in order:
    ///
    /// 1. **Scheme gate.** Remote sources can put any string in a row's URL
    ///    — ntfy topics are public by default, and a JSON feed is whatever
    ///    its publisher serves. `NSWorkspace.open` honours every registered
    ///    handler, so `shortcuts://run-shortcut?…` would run a Shortcut and
    ///    `file:///Applications/…` would launch an app. Only `http`/`https`
    ///    and the deep-links this app itself emits (`slack`, `message`) are
    ///    opened unconditionally; `file` and `claude` are local-source-only
    ///    — the `inchill` CLI / agent hooks set the cwd and session id, not
    ///    a remote publisher. Everything else is refused; the caller names
    ///    the scheme in `openProblem` rather than silently dropping it.
    /// 2. **Slack fallback.** A `slack://` deep link is dead on a Mac
    ///    without Slack installed, so the https permalink rides along in
    ///    the payload and is used instead when nothing handles the scheme.
    static func openable(
        _ url: URL, sourceKind: String, payload: Data?
    ) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "http", "https", "message":
            return url
        case "slack":
            // Deep link, with the https permalink as the fallback when no
            // app on this Mac registers the `slack` scheme.
            guard !handlesSlackScheme(),
                let payload,
                let fallback = SlackConnector.permalink(in: payload),
                let web = URL(string: fallback)
            else { return url }
            return web
        case "file", "claude":
            // A remote push must not open local files or session URIs.
            return sourceKind == "local" ? url : nil
        case "x-apple-reminderkit":
            // Reminders' own deep link, and local-only for the same reason:
            // the URL is constructed by `RemindersConnector` from an EventKit
            // identifier, never supplied by anything remote. Launch Services
            // resolves the scheme to Reminders.app (measured 2026-08-26);
            // whether this exact path lands on the right reminder is NOT
            // verified, so a miss is a no-op rather than a wrong app opening.
            return sourceKind == "reminders" ? url : nil
        default:
            return nil
        }
    }

    /// Cached: it's a Launch Services round trip, and the answer only
    /// changes if the user installs or removes Slack mid-session.
    private static let slackSchemeHandled: Bool = {
        guard let probe = URL(string: "slack://channel") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }()

    private static func handlesSlackScheme() -> Bool { slackSchemeHandled }

    func markDone(_ item: Item) {
        undoStack.append([item.uid])
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

    /// Dismiss several rows as one action — a topic, or a multi-selection.
    ///
    /// One undo entry, one store write, and one journal line per member: the
    /// journal records notifications, not UI gestures, so a grouped dismissal
    /// still leaves four lines. `detail` names the topic when there is one,
    /// which is what makes those four lines legible later.
    func markDone(_ items: [Item], topicName: String? = nil) {
        let targets = items.filter { !$0.isDone }
        guard !targets.isEmpty else { return }
        undoStack.append(targets.map(\.uid))
        journal(.done, items: targets) { item in
            Self.waited(item, topicName: topicName)
        }
        let batch = targets.map(target(for:))
        Task { await engine.markDone(batch: batch) }
    }

    /// Sources whose rows can be completed with `C`.
    ///
    /// Rebuilt by `bootstrapConnectors`, which is also what runs when a source
    /// is saved or toggled — so this cannot drift from the registered
    /// connectors without the connectors themselves having changed.
    private(set) var completesTaskSourceIDs: Set<String> = []

    /// Whether `C` means anything for this row.
    func canComplete(_ item: Item) -> Bool {
        completesTaskSourceIDs.contains(item.sourceID)
    }

    func canCompleteAll(_ items: [Item]) -> Bool {
        !items.isEmpty && items.allSatisfy(canComplete)
    }

    /// `C` — finish the task in its source, and take the row out of the queue.
    ///
    /// Distinct from `markDone` by design: dismissing a to-do leaves the task
    /// open in Reminders and keeps the row in the archive, and this is the only
    /// thing that actually ticks it off. Goes on the same undo stack, and
    /// `restore` reopens it remotely.
    func completeTask(_ item: Item) {
        guard canComplete(item) else {
            openProblem =
                "Only to-do sources can be completed. Press E to dismiss this instead."
            return
        }
        undoStack.append([item.uid])
        journal(
            .completed, item: item,
            detail: JournalWriter.waited(from: item.firstSeenAt, to: .now))
        let (uid, sourceID, ext, payload) =
            (item.uid, item.sourceID, externalID(of: item), item.payload)
        Task {
            await engine.completeTask(
                uid: uid, sourceID: sourceID, externalID: ext, payload: payload)
        }
    }

    /// `C` over several rows — all or nothing.
    ///
    /// Refuses a mixed set out loud rather than half-finishing it: completing
    /// three of four members and silently skipping the Slack one is the
    /// rule-5 failure this app exists to avoid.
    func completeTask(_ items: [Item], topicName: String? = nil) {
        guard canCompleteAll(items) else {
            openProblem =
                items.isEmpty
                ? "Nothing to complete."
                : "Only to-do sources can be completed, and not every item here is one. Press E to dismiss them instead."
            return
        }
        undoStack.append(items.map(\.uid))
        journal(.completed, items: items) { item in
            Self.waited(item, topicName: topicName)
        }
        let batch = items.map(target(for:))
        Task { await engine.completeTask(batch: batch) }
    }

    func snooze(_ items: [Item], until: Date, topicName: String? = nil) {
        let targets = items.filter { !$0.isDone }
        guard !targets.isEmpty else { return }
        let when = Self.journalDateFormatter.string(from: until)
        journal(.snoozed, items: targets) { _ in
            topicName.map { "until \(when) · \($0)" } ?? "until \(when)"
        }
        let batch = targets.map(target(for:))
        Task { await engine.snooze(batch: batch, until: until) }
    }

    /// Pins or unpins several rows to the same state.
    ///
    /// Normalizing rather than flipping each: "pin this topic" has to mean
    /// one thing, and a mixed topic flipped member-by-member stays mixed
    /// forever. Same rule the main window already applies to a mixed
    /// selection — it now shares this implementation.
    func setPinned(_ items: [Item], pinned: Bool) {
        let targets = items.filter { $0.isPinned != pinned }
        guard !targets.isEmpty else { return }
        journal(pinned ? .pinned : .unpinned, items: targets)
        let uids = targets.map(\.uid)
        Task {
            try? await store.setPinned(uids: uids, pinned: pinned)
            await MainActor.run { queueVersion += 1 }
            await refreshBadge()
        }
    }

    /// ⌘Z — undo the last action, however many rows it touched.
    func undoDone() {
        guard let entry = undoStack.popLast() else { return }
        guard entry.count > 1 else {
            if let uid = entry.first { restore(uid: uid, popped: true) }
            return
        }
        let restored = entry.compactMap(item(forUID:))
        if journalEnabled, journalLogActions, !restored.isEmpty {
            journal(.restored, items: restored)
        }
        let batch = entry.map { uid in
            item(forUID: uid).map(target(for:))
                ?? SyncEngine.Target(
                    uid: uid, sourceID: sourceID(forUID: uid),
                    externalID: "", payload: nil)
        }
        Task { await engine.undoDone(batch: batch) }
    }

    /// `U` over several rows, normalized to the same state.
    func setSeen(_ items: [Item], seen: Bool) {
        let targets = items.filter { $0.isSeen != seen }
        guard !targets.isEmpty else { return }
        let uids = targets.map(\.uid)
        Task {
            try? await store.setSeen(uids: uids, seen: seen)
            await MainActor.run { queueVersion += 1 }
        }
    }

    // MARK: Topics

    /// Groups items under a new topic, and reports its id.
    ///
    /// The terms back-fill inside the store, so making a topic for
    /// `EPD-1873` gathers the rows already mentioning it rather than only the
    /// ones that happened to be marked.
    @discardableResult
    func createTopic(
        name: String, terms: [String], members: [Item]
    ) -> String {
        let id = UUID().uuidString
        let uids = members.map(\.uid)
        Task {
            _ = try? await store.createTopic(
                id: id, name: name, terms: terms, memberUIDs: uids)
            await MainActor.run { queueVersion += 1 }
            await refreshBadge()
        }
        return id
    }

    func addToTopic(id: String, members: [Item]) {
        let uids = members.map(\.uid)
        Task {
            try? await store.addToTopic(id: id, uids: uids)
            await MainActor.run { queueVersion += 1 }
            await refreshBadge()
        }
    }

    func removeFromTopic(_ members: [Item]) {
        let uids = members.map(\.uid)
        Task {
            try? await store.removeFromTopic(uids: uids)
            await MainActor.run { queueVersion += 1 }
            await refreshBadge()
        }
    }

    func renameTopic(id: String, name: String, terms: [String]) {
        Task {
            try? await store.renameTopic(id: id, name: name, terms: terms)
            await MainActor.run { queueVersion += 1 }
            await refreshBadge()
        }
    }

    /// Dissolves a topic. Members go back to their source sections — nothing
    /// is dismissed, and this is the reason "Ungroup" can be offered without
    /// a confirmation.
    func deleteTopic(id: String) {
        Task {
            try? await store.deleteTopic(id: id)
            await MainActor.run { queueVersion += 1 }
            await refreshBadge()
        }
    }

    private func target(for item: Item) -> SyncEngine.Target {
        SyncEngine.Target(
            uid: item.uid, sourceID: item.sourceID,
            externalID: externalID(of: item), payload: item.payload)
    }

    /// "waited 4m" for a lone row, "waited 4m · EPD-1873" inside a topic.
    private static func waited(
        _ item: Item, topicName: String?
    ) -> String? {
        let waited = JournalWriter.waited(from: item.firstSeenAt, to: .now)
        guard let topicName else { return waited }
        guard let waited else { return topicName }
        return "\(waited) · \(topicName)"
    }

    /// Bring a done item back to the queue (⌘Z and archive Restore).
    ///
    /// Carries the external id and payload as well as the source, because a
    /// row that was *completed* rather than dismissed has to be reopened in
    /// its source too — the engine decides which, from the reason the store
    /// recorded. Restoring a dismissal is unaffected; nothing is written.
    func restore(uid: String, popped: Bool = false) {
        let restored = item(forUID: uid)
        if journalEnabled, journalLogActions, let restored {
            journal(.restored, item: restored)
        }
        // Restoring a row from the archive has to take it out of every undo
        // entry it appears in, or a later ⌘Z would "undo" a row that is
        // already back. An entry emptied that way is dropped rather than
        // left as a ⌘Z that does nothing.
        if !popped {
            for index in undoStack.indices {
                undoStack[index].removeAll { $0 == uid }
            }
            undoStack.removeAll(where: \.isEmpty)
        }
        let sourceID = restored?.sourceID ?? sourceID(forUID: uid)
        let ext = restored.map(externalID(of:)) ?? ""
        let payload = restored?.payload
        Task {
            await engine.undoDone(
                uid: uid, sourceID: sourceID, externalID: ext, payload: payload)
        }
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

    // MARK: Row context (D expansion)

    /// The fully-expanded row's context request. One row can hold D at a
    /// time (`PanelView.isFullyExpanded`), so one phase is the whole state.
    private(set) var rowContext: RowContextPhase = .idle
    /// Which item `rowContext` belongs to — a stale answer for a row the
    /// selection has left must never paint the row it moved to.
    private(set) var rowContextUID: String?
    private var rowContextTask: Task<Void, Never>?
    /// Slack context includes "messages after", which keeps changing, so
    /// answers age out rather than living for the session.
    private var rowContextCache: [String: (context: ItemContext, at: Date)] = [:]
    private static let rowContextTTL: TimeInterval = 180

    /// Kicks off (or replays from cache) the context fetch for a row the
    /// user just fully expanded. Quietly does nothing for sources without
    /// `.providesContext` — the engine answers `.unavailable` and the row
    /// simply has no context section, same as before the feature existed.
    func fetchContext(for item: Item) {
        rowContextTask?.cancel()
        rowContextUID = item.uid
        if let cached = rowContextCache[item.uid],
            Date.now.timeIntervalSince(cached.at) < Self.rowContextTTL {
            rowContext = .loaded(cached.context)
            return
        }
        rowContext = .loading
        let (uid, sourceID, ext, payload) =
            (item.uid, item.sourceID, externalID(of: item), item.payload)
        rowContextTask = Task {
            let fetched = await engine.fetchContext(
                sourceID: sourceID, externalID: ext, payload: payload)
            guard !Task.isCancelled, rowContextUID == uid else { return }
            switch fetched {
            case .context(let context):
                rowContextCache[uid] = (context, .now)
                rowContext = .loaded(context)
            case .unavailable:
                rowContext = .idle
            case .failed(let reason):
                rowContext = .failed(reason)
            }
        }
    }

    /// Collapsing the row (or moving the selection) drops the request — a
    /// late answer must not grow a row that is back to one line.
    func clearContext() {
        rowContextTask?.cancel()
        rowContextTask = nil
        rowContextUID = nil
        rowContext = .idle
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

