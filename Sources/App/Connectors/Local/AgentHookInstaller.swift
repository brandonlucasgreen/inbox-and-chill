import Foundation

/// Installs `inchill` hook commands into an agent CLI's own config file, so
/// its sessions post to the local triage queue.
///
/// Claude Code, Codex CLI and Gemini CLI all take the **same shape** of
/// config — a JSON object with a `hooks` key, each event holding an array of
/// `{ "matcher": …, "hooks": [{ "type": "command", "command": … }] }` — and
/// all three hand the hook `session_id` and `cwd` as JSON on stdin. So the
/// machinery here is written once and the three differ only in a file path
/// and an event-name mapping (see `AgentHooks`).
///
/// The four *semantic* events are the same everywhere, because they are
/// properties of an agent session rather than of a vendor: something wants
/// you, a turn ended, you replied, the session is gone. Each harness maps its
/// own spellings onto those (`ClaudeHook.Event`), which is why the `inchill`
/// side needs no per-harness branching at all.
///
/// Writes are non-destructive in the same three ways for every harness:
/// unknown keys are preserved verbatim, the file is copied to a timestamped
/// backup before every write, and entries we previously wrote are replaced
/// rather than duplicated. That matters more than it used to — other tools
/// (Vibe Island, Bartender's NotchBar, the user's own scripts) already own
/// entries in these exact files, so an installer that overwrote would break
/// somebody else's integration.
struct AgentHookInstaller: Identifiable, Equatable {
    struct IntegrationError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        var description: String { errorDescription ?? "Hook integration error" }
    }

    enum InstallState: Equatable {
        case notInstalled
        case outdated
        case installed
    }

    /// Matches `ClaudeHook.Harness.id` — "claude", "codex", "gemini".
    var id: String
    /// "Claude Code", "Codex CLI", "Gemini CLI".
    var displayName: String
    /// The harness's own config directory, e.g. `~/.claude`. Its **existence
    /// is the test for whether the user has this tool at all**.
    var directory: URL
    /// The file we merge into, e.g. `~/.claude/settings.json`.
    var settingsURL: URL
    /// How that file is written in user-facing text.
    var settingsLabel: String
    /// The `inchill` sub-command this harness's hooks call.
    var subcommand: String
    /// The harness's event name → the semantic argument we pass `inchill`.
    /// Order is the install order; count is what `installState` compares.
    var events: [HookEvent]

    struct HookEvent: Equatable {
        var event: String
        var argument: String
    }

    // MARK: - Presence

    /// Whether this agent CLI appears to be installed at all.
    ///
    /// **The app must never create a config directory for a tool the user
    /// does not use.** Writing `~/.codex/hooks.json` onto the Mac of someone
    /// who has never run Codex is litter at best and confusing at worst, and
    /// it would make Inbox & Chill look like it was trying to be everywhere.
    /// So a missing directory means this harness simply does not exist for
    /// this user — not "not set up yet".
    var isPresent: Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    /// Per-harness, so turning Gemini off says nothing about Claude Code.
    /// Claude's key keeps its original spelling — anyone who already pressed
    /// Remove must stay opted out across this change.
    var userDeclinedKey: String {
        id == "claude" ? "claudeHooks.userDeclined" : "\(id)Hooks.userDeclined"
    }

    var userDeclined: Bool {
        get { UserDefaults.standard.bool(forKey: userDeclinedKey) }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: userDeclinedKey)
        }
    }

    // MARK: - State

    var installState: InstallState {
        guard let settings = try? readSettings() else { return .notInstalled }
        let current = events.filter {
            hasEntry(
                in: settings, event: $0.event,
                matching: command(forHookNamed: $0.argument))
        }
        if current.count == events.count { return .installed }
        return Self.hasAnyInchillEntry(in: settings) ? .outdated : .notInstalled
    }

    var isInstalled: Bool { installState == .installed }

    /// Whether the app should write these hooks itself, right now.
    ///
    /// Pure so the policy is testable without touching any real config
    /// (rule 6). `.outdated` counts: those are *our* entries pointing at a
    /// command we no longer write (usually the app moved), so rewriting
    /// repairs something already broken rather than adding anything new.
    nonisolated static func shouldAutoInstall(
        state: InstallState, userDeclined: Bool, harnessIsPresent: Bool,
        hasEnabledLocalSource: Bool
    ) -> Bool {
        guard hasEnabledLocalSource, harnessIsPresent, !userDeclined else {
            return false
        }
        return state != .installed
    }

    /// What to say when the app tried to write hooks and could not.
    ///
    /// Auto-installation fails silently by nature — nobody pressed anything,
    /// so there is no sheet to keep open and no button to turn red. This
    /// sentence is the only account the user gets, so it names the tool, the
    /// file and the way out (rule 5).
    nonisolated static func explainAutoInstallFailure(
        _ error: Error, displayName: String, settingsLabel: String
    ) -> String {
        "Couldn't set up the \(displayName) hooks in \(settingsLabel), so its "
            + "sessions won't reach the queue: \(String(describing: error)) "
            + "You can retry below, or add them by hand from the same file."
    }

    static func hasAnyInchillEntry(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                innerCommands(of: entry).contains { $0.contains("inchill") }
            }
        }
    }

    // MARK: - Install / uninstall

    func installHooks() throws {
        // Never bring a harness's config into existence. `installState` for a
        // missing directory reads `.notInstalled`, which is indistinguishable
        // from "present but unconfigured" without this guard.
        guard isPresent else {
            throw IntegrationError(
                errorDescription:
                    "\(displayName) doesn't appear to be installed — there's no \(directory.lastPathComponent) directory in your home folder, so there's nothing to add hooks to."
            )
        }
        let existing = try readSettings()
        try backupIfExists()

        var settings = existing
        for hook in events {
            settings = merge(
                settings: settings, event: hook.event,
                command: command(forHookNamed: hook.argument))
        }
        try writeSettings(settings)
    }

    func uninstallHooks() throws {
        guard let existing = try? readSettings(), !existing.isEmpty else { return }
        try backupIfExists()

        var settings = existing
        // Every event we have *ever* managed, not just the current list:
        // uninstalling after a version that installed a different set must
        // not leave orphans behind.
        let allEvents = Array((settings["hooks"] as? [String: Any] ?? [:]).keys)
        for event in allEvents {
            settings = removeInchillEntries(from: settings, event: event)
        }
        try writeSettings(settings)
    }

    // MARK: - Locating the CLI

    /// The bundled copy wins so hooks keep working after an app update; a
    /// `/usr/local/bin` install is the fallback for a separate install.
    private func inchillPath() -> String {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "inchill"),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return bundled.path
        }
        return "/usr/local/bin/inchill"
    }

    private func command(forHookNamed hook: String) -> String {
        "\(Self.shellQuoted(inchillPath())) \(subcommand) \(hook)"
    }

    /// Every one of these harnesses runs a hook command through a shell, so
    /// the path has to survive word splitting — and our bundle is named
    /// "Inbox & Chill.app", whose unquoted `&` a shell reads as a
    /// background-job separator (splitting the command into two nonexistent
    /// ones, both silently failing).
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: - Config read/write

    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw IntegrationError(
                errorDescription:
                    "\(settingsLabel) isn't a JSON object; refusing to modify it."
            )
        }
        return object
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func backupIfExists() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return
        }
        let timestamp = Int(Date.now.timeIntervalSince1970)
        let name = settingsURL.lastPathComponent
        let backupURL = directory.appending(
            path: "\(name).inchill-backup-\(timestamp)")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.copyItem(at: settingsURL, to: backupURL)
    }

    // MARK: - hooks.<Event> merging

    private func merge(
        settings: [String: Any], event: String, command: String
    ) -> [String: Any] {
        // Drop any entry we wrote previously before appending the current
        // one, so re-installing rewrites a stale command instead of leaving
        // the broken one in place.
        var settings = removeInchillEntries(from: settings, event: event)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var entries = (hooks[event] as? [[String: Any]]) ?? []

        entries.append([
            "matcher": "",
            "hooks": [["type": "command", "command": command]],
        ])

        hooks[event] = entries
        settings["hooks"] = hooks
        return settings
    }

    private func removeInchillEntries(
        from settings: [String: Any], event: String
    ) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
            let entries = hooks[event] as? [[String: Any]]
        else { return settings }

        let filtered: [[String: Any]] = entries.compactMap { entry in
            guard var innerHooks = entry["hooks"] as? [[String: Any]] else {
                return entry
            }
            innerHooks.removeAll {
                ($0["command"] as? String)?.contains("inchill") == true
            }
            guard !innerHooks.isEmpty else { return nil }
            var entry = entry
            entry["hooks"] = innerHooks
            return entry
        }

        hooks[event] = filtered
        settings["hooks"] = hooks
        return settings
    }

    private func hasEntry(
        in settings: [String: Any], event: String, matching command: String
    ) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
            let entries = hooks[event] as? [[String: Any]]
        else { return false }
        return entries.contains { entry in
            Self.innerCommands(of: entry).contains { $0 == command }
        }
    }

    private static func innerCommands(of entry: [String: Any]) -> [String] {
        guard let innerHooks = entry["hooks"] as? [[String: Any]] else {
            return []
        }
        return innerHooks.compactMap { $0["command"] as? String }
    }
}

/// The three agent CLIs the app can wire itself into.
///
/// Event mappings come from each vendor's hooks documentation. **Only Claude
/// Code's has been exercised against the real tool** — Codex and Gemini were
/// mapped from their docs and verified only by replaying their documented
/// stdin payload through `inchill` by hand, so treat their event *names* as
/// the unverified part (rule 4).
enum AgentHooks {
    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var claudeCode: AgentHookInstaller {
        AgentHookInstaller(
            id: "claude", displayName: "Claude Code",
            directory: home.appending(path: ".claude"),
            settingsURL: home.appending(path: ".claude/settings.json"),
            settingsLabel: "~/.claude/settings.json",
            subcommand: "claude-hook",
            events: [
                .init(event: "Notification", argument: "notification"),
                .init(event: "Stop", argument: "stop"),
                .init(event: "UserPromptSubmit", argument: "user-prompt-submit"),
                .init(event: "SessionEnd", argument: "session-end"),
            ])
    }

    /// Codex writes hooks to their own file rather than into `config.toml`,
    /// and merges scopes rather than replacing them — so adding entries is
    /// safe even though the `impeccable` skill already owns some.
    ///
    /// `PermissionRequest` stands in for Claude Code's `Notification`. The
    /// one real gap: Codex has **no idle event**, so a Codex row cannot
    /// escalate from low to high signal the way an ignored Claude Code
    /// session does — it will sit at whatever signal its last event set.
    static var codex: AgentHookInstaller {
        AgentHookInstaller(
            id: "codex", displayName: "Codex CLI",
            directory: home.appending(path: ".codex"),
            settingsURL: home.appending(path: ".codex/hooks.json"),
            settingsLabel: "~/.codex/hooks.json",
            subcommand: "codex-hook",
            events: [
                .init(event: "PermissionRequest", argument: "notification"),
                .init(event: "Stop", argument: "stop"),
                .init(event: "UserPromptSubmit", argument: "user-prompt-submit"),
                .init(event: "SessionEnd", argument: "session-end"),
            ])
    }

    /// Gemini is the closest match of the three: it has a real `Notification`
    /// event, so all four signals map one-to-one.
    static var gemini: AgentHookInstaller {
        AgentHookInstaller(
            id: "gemini", displayName: "Gemini CLI",
            directory: home.appending(path: ".gemini"),
            settingsURL: home.appending(path: ".gemini/settings.json"),
            settingsLabel: "~/.gemini/settings.json",
            subcommand: "gemini-hook",
            events: [
                .init(event: "Notification", argument: "notification"),
                .init(event: "AfterAgent", argument: "stop"),
                .init(event: "BeforeAgent", argument: "user-prompt-submit"),
                .init(event: "SessionEnd", argument: "session-end"),
            ])
    }

    static var all: [AgentHookInstaller] { [claudeCode, codex, gemini] }

    /// Only the harnesses actually on this Mac. Everything user-facing reads
    /// from this, so someone who has never installed Codex never sees a row
    /// about it.
    static var present: [AgentHookInstaller] { all.filter(\.isPresent) }
}
