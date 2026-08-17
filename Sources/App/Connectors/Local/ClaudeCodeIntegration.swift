import Foundation

/// Installs/removes the `inchill claude-hook` commands in
/// `~/.claude/settings.json` so Claude Code's `Notification` and `Stop`
/// hooks feed the local triage queue.
///
/// Convention (see `Sources/CLI/main.swift` for the implementation):
///   - `Notification` fires when a session wants the user (a permission
///     prompt, or idle waiting for input) → `inchill claude-hook
///     notification` posts `/notify` with externalID `claude-<session_id>`,
///     kind `claude_waiting`, high-signal.
///   - `Stop` fires when a turn ends (Claude finished, it's the user's turn)
///     → `inchill claude-hook stop` posts `/clear` for `claude-<session_id>`
///     (the waiting item, if any, disappears) and a fresh low-signal
///     `claude_done` item so a finished-but-unattended session still shows
///     up in the queue.
///
/// All writes to `~/.claude/settings.json` are non-destructive: unknown keys
/// (other hooks, unrelated settings) are preserved verbatim, and the
/// pre-existing file is copied to a timestamped backup before every write.
enum ClaudeCodeIntegration {
    struct IntegrationError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        var description: String { errorDescription ?? "Claude Code integration error" }
    }

    private static let claudeDirectory = FileManager.default
        .homeDirectoryForCurrentUser.appending(path: ".claude")
    private static let settingsURL = claudeDirectory.appending(path: "settings.json")

    private static let hookEvents = ["Notification", "Stop"]

    // MARK: - Public API

    static var isInstalled: Bool {
        guard let settings = try? readSettings() else { return false }
        return hookEvents.allSatisfy { hasInchillEntry(in: settings, event: $0) }
    }

    static func installHooks() throws {
        let existing = try readSettings()
        try backupIfExists()

        var settings = existing
        for event in hookEvents {
            settings = merge(
                settings: settings, event: event,
                command: command(forHookNamed: event.lowercased()))
        }
        try writeSettings(settings)
    }

    static func uninstallHooks() throws {
        guard let existing = try? readSettings(), !existing.isEmpty else { return }
        try backupIfExists()

        var settings = existing
        for event in hookEvents {
            settings = removeInchillEntries(from: settings, event: event)
        }
        try writeSettings(settings)
    }

    // MARK: - Locating the CLI

    /// The bundled copy (installed as a Copy Files build phase alongside the
    /// app) wins so hooks keep working after the CLI is updated by an app
    /// update; a `/usr/local/bin` install (e.g. via `brew` or a manual
    /// symlink) is the fallback for anyone who installed it separately.
    private static func inchillPath() -> String {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "inchill"),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return bundled.path
        }
        return "/usr/local/bin/inchill"
    }

    private static func command(forHookNamed hook: String) -> String {
        "\(inchillPath()) claude-hook \(hook)"
    }

    // MARK: - settings.json read/write

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError(
                errorDescription: "~/.claude/settings.json isn't a JSON object; refusing to modify it.")
        }
        return object
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: claudeDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Copies the raw, on-disk `settings.json` to a timestamped sibling
    /// before any write. No-op if the file doesn't exist yet (nothing to
    /// back up).
    private static func backupIfExists() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let timestamp = Int(Date.now.timeIntervalSince1970)
        let backupURL = claudeDirectory.appending(
            path: "settings.json.inchill-backup-\(timestamp)")
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }
        try FileManager.default.copyItem(at: settingsURL, to: backupURL)
    }

    // MARK: - hooks.<Event> merging
    //
    // Schema (matches Claude Code's real hooks format):
    //   "hooks": { "<Event>": [ { "matcher": "", "hooks": [
    //     { "type": "command", "command": "..." } ] } ] }

    private static func merge(
        settings: [String: Any], event: String, command: String
    ) -> [String: Any] {
        var settings = settings
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var entries = (hooks[event] as? [[String: Any]]) ?? []

        let alreadyPresent = entries.contains { entry in
            innerCommands(of: entry).contains { $0.contains("inchill") }
        }
        if !alreadyPresent {
            entries.append([
                "matcher": "",
                "hooks": [
                    ["type": "command", "command": command]
                ],
            ])
        }

        hooks[event] = entries
        settings["hooks"] = hooks
        return settings
    }

    private static func removeInchillEntries(
        from settings: [String: Any], event: String
    ) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
            let entries = hooks[event] as? [[String: Any]]
        else { return settings }

        let filtered: [[String: Any]] = entries.compactMap { entry in
            guard var innerHooks = entry["hooks"] as? [[String: Any]] else { return entry }
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

    private static func hasInchillEntry(in settings: [String: Any], event: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
            let entries = hooks[event] as? [[String: Any]]
        else { return false }
        return entries.contains { entry in
            innerCommands(of: entry).contains { $0.contains("inchill") }
        }
    }

    private static func innerCommands(of entry: [String: Any]) -> [String] {
        guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return [] }
        return innerHooks.compactMap { $0["command"] as? String }
    }
}
