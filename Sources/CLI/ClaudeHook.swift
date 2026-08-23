// Payload mapping for `inchill claude-hook` — kept apart from main.swift so
// the tests can call it directly (CLAUDE.md rule 6). Foundation-only, like
// the rest of the `inchill` target: it must not link the app's modules.

import Foundation

/// Turns a Claude Code hook event into the one HTTP request it should make.
///
/// **One item per session, not one per turn.** Every request here addresses
/// `claude-<session_id>` — a session-stable id — so a session occupies
/// exactly one row in the queue for its whole life, updated in place. The
/// original convention gave the `Stop` hook a timestamped id
/// (`claude-done-<session>-<epoch>`), which meant a fresh row at the end of
/// *every turn*: a thirty-turn session left thirty rows, all of them saying
/// the same thing, and the one fact worth keeping — this session is waiting
/// on you — was buried in its own duplicates.
///
/// The four events and what each one means for that single row:
///
/// - `Notification` — Claude wants the user (a permission prompt, or 60s
///   idle with no input). Upserts the row, high-signal.
/// - `Stop` — a turn ended, so it is the user's move. Upserts the same row,
///   low-signal, carrying what Claude last said.
/// - `UserPromptSubmit` — the user replied. **Clears** the row: the session
///   is no longer waiting on anyone, and this is what keeps the queue
///   meaning "sessions awaiting my reply" rather than "sessions I have ever
///   run". Without it a live session's row never leaves.
/// - `SessionEnd` — the session is gone and cannot be waiting for anything.
///   Clears the row.
///
/// Signal escalates on its own, which is why `Stop` staying low-signal is
/// deliberate rather than an oversight: a finished session you ignore goes
/// idle, `Notification` fires ~60s later, and the same row turns
/// high-signal. Urgency rises with neglect without anything having to track
/// neglect.
enum ClaudeHook {
    /// The hook events we install, paired with the sub-command argument
    /// written into `~/.claude/settings.json`.
    ///
    /// The two original spellings (`notification`, `stop`) are load-bearing:
    /// they are what existing installs already have on disk, and changing
    /// them would strand every hook installed before this version.
    ///
    /// These four are **semantic, not harness-specific**: every agent CLI we
    /// support maps its own event names onto them (Codex's
    /// `PermissionRequest` and Gemini's `Notification` both arrive as
    /// `notification`), so the CLI keeps one vocabulary and only the
    /// installer's mapping table changes per harness.
    enum Event: String, CaseIterable {
        case notification = "notification"
        case stop = "stop"
        case userPromptSubmit = "user-prompt-submit"
        case sessionEnd = "session-end"
    }

    /// Which agent CLI a hook fired from.
    ///
    /// Only three things actually vary: the queue id prefix (so two harnesses
    /// running in the same folder can never collide on one row), the item
    /// `kind` prefix, and the words a row shows. Everything else — one row
    /// per session, the clear-on-reply rule, signal escalation — is identical,
    /// because it is a property of *agent sessions*, not of any one vendor.
    struct Harness: Equatable {
        /// Prefixes both the queue id (`codex-<session>`) and the item kind
        /// (`codex_waiting`).
        var id: String
        /// What a row calls the agent mid-sentence: "Claude finished in …".
        var agentName: String
        /// What a row calls the product when naming it outright: "Claude Code
        /// needs your input". Distinct from `agentName` because Claude Code's
        /// two existing strings already used both spellings, and rewording
        /// shipped rows is not what this change is for.
        var productName: String
        /// The `source` field on the posted JSON.
        var sourceName: String
        /// The `inchill` sub-command that carries this harness's events.
        var subcommand: String

        static let claudeCode = Harness(
            id: "claude", agentName: "Claude", productName: "Claude Code",
            sourceName: "claude-code", subcommand: "claude-hook")
        static let codex = Harness(
            id: "codex", agentName: "Codex", productName: "Codex",
            sourceName: "codex-cli", subcommand: "codex-hook")
        static let gemini = Harness(
            id: "gemini", agentName: "Gemini", productName: "Gemini CLI",
            sourceName: "gemini-cli", subcommand: "gemini-hook")

        static let all: [Harness] = [.claudeCode, .codex, .gemini]

        static func named(_ subcommand: String) -> Harness? {
            all.first { $0.subcommand == subcommand }
        }
    }

    /// One request to the app's local listener.
    struct Request: Equatable {
        var path: String
        var itemID: String
        /// Non-nil only for `/notify`; a `/clear` carries just the id.
        var title: String?
        var kind: String?
        var body: String?
        var highSignal: Bool?
    }

    /// The queue id for a session. Stable for the session's whole life —
    /// this is the entire consolidation mechanism.
    ///
    /// Prefixed per harness so a Codex session and a Claude Code session can
    /// never land on the same row, even in the same folder.
    static func itemID(sessionID: String, harness: Harness = .claudeCode)
        -> String
    {
        "\(harness.id)-\(sessionID)"
    }

    /// What the app calls the source. Decorative today (LocalConnector uses
    /// its own source id), but it is what a human sees in a payload dump.
    static let sourceName = "claude-code"

    static func request(
        for event: Event, sessionID: String, cwd: String? = nil,
        message: String? = nil, lastAssistantMessage: String? = nil,
        harness: Harness = .claudeCode
    ) -> Request {
        let id = itemID(sessionID: sessionID, harness: harness)
        switch event {
        case .notification:
            return Request(
                path: "/notify", itemID: id,
                title: message?.isEmpty == false
                    ? message! : "\(harness.productName) needs your input",
                kind: "\(harness.id)_waiting",
                body: "in \(directoryName(for: cwd))",
                highSignal: true)

        case .stop:
            return Request(
                path: "/notify", itemID: id,
                title:
                    "\(harness.agentName) finished in \(directoryName(for: cwd))",
                kind: "\(harness.id)_done",
                // What it actually said beats a bare "finished" when you are
                // scanning several sessions at once.
                body: firstLine(of: lastAssistantMessage),
                highSignal: false)

        case .userPromptSubmit, .sessionEnd:
            return Request(path: "/clear", itemID: id)
        }
    }

    /// The last path component of the session's working directory, or
    /// `unknown` — a hook that cannot tell where it is must still post.
    static func directoryName(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        return (cwd as NSString).lastPathComponent
    }

    /// A `file://` URL for the session's working directory.
    ///
    /// The item's `url` and the last resort for ⏎: what it falls back to when
    /// the session it came from can no longer be found (its window closed,
    /// its terminal quit). `sessionOrigin()` in main.swift is what makes ⏎
    /// land in the session itself.
    static func projectURL(for cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).absoluteString
    }

    /// First non-empty line, trimmed to something that fits a queue row.
    static func firstLine(of text: String?, limit: Int = 200) -> String? {
        guard let text else { return nil }
        guard
            let line = text.split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
        else { return nil }
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
