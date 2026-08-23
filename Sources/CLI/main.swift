// inchill — command-line companion for Inbox & Chill.
//
// Posts to the app's localhost HTTP listener (see
// Sources/App/Connectors/Local/LocalListener.swift) to push and clear items
// in the triage queue from the terminal or from Claude Code hooks. This file
// is deliberately Foundation-only and dependency-free — the `inchill` target
// doesn't (and shouldn't) link against the app's Swift modules.
//
// Usage:
//   inchill notify [--id X] [--source S] [--kind K] --title T [--body B] [--url U] [--low]
//   inchill done <id>
//   inchill clear <id>
//   inchill claude-hook <notification|stop|user-prompt-submit|session-end>

import Foundation

// MARK: - Local API discovery

/// Mirrors LocalListener's `~/Library/Application Support/InboxAndChill/local-api.json`.
private struct LocalAPIInfo: Decodable {
    var port: Int
    var token: String
}

private func loadLocalAPIInfo() -> LocalAPIInfo? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/InboxAndChill/local-api.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(LocalAPIInfo.self, from: data)
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// MARK: - HTTP (synchronous, semaphore-gated — this CLI is a one-shot process)

/// Box for handing a result back out of `URLSession`'s completion closure
/// without a captured `var` (the closure can run on an arbitrary background
/// queue).
private final class RequestOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var succeeded = false
    private(set) var failureMessage: String?

    func succeed() {
        lock.lock(); defer { lock.unlock() }
        succeeded = true
    }

    func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        failureMessage = message
    }
}

/// Posts to the app's listener.
///
/// `bestEffort` is for the Claude Code hooks, and it is a deliberate
/// exception to this project's "never fail silently" rule (CLAUDE.md rule
/// 5) rather than an oversight. A hook whose only job is to tidy a queue
/// must not interrupt the work it is observing: `UserPromptSubmit` in
/// particular runs on every prompt the user sends, so a non-zero exit while
/// the app happens to be closed would put an error in front of them every
/// single time they typed. The failure still goes to stderr — visible in
/// Claude Code's ctrl-R transcript — and the app has its own, better place
/// to say it is not receiving hooks: the Settings integration row.
@discardableResult
private func post(path: String, json: [String: Any], bestEffort: Bool = false) -> Bool {
    func giveUp(_ message: String) -> Bool {
        if bestEffort {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return false
        }
        fail(message)
    }

    guard let info = loadLocalAPIInfo() else {
        return giveUp("Inbox & Chill isn't running (or local sources are off).")
    }
    guard let url = URL(string: "http://127.0.0.1:\(info.port)\(path)") else {
        return giveUp("inchill: could not construct request URL for \(path).")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(info.token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: json)

    let semaphore = DispatchSemaphore(value: 0)
    let outcome = RequestOutcome()

    let task = URLSession.shared.dataTask(with: request) { _, response, error in
        defer { semaphore.signal() }
        if let error {
            outcome.fail("inchill: request to \(path) failed: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse else {
            outcome.fail("inchill: no HTTP response from \(path).")
            return
        }
        guard (200...299).contains(http.statusCode) else {
            outcome.fail("inchill: \(path) returned status \(http.statusCode).")
            return
        }
        outcome.succeed()
    }
    task.resume()

    if semaphore.wait(timeout: .now() + 5) == .timedOut {
        return giveUp("inchill: timed out waiting for Inbox & Chill to respond.")
    }
    if let failureMessage = outcome.failureMessage {
        return giveUp(failureMessage)
    }
    return outcome.succeeded
}

// MARK: - notify

private struct NotifyOptions {
    var id: String?
    var source: String?
    var kind: String?
    var title: String?
    var body: String?
    var url: String?
    var low = false
}

private func parseNotifyArgs(_ args: [String]) -> NotifyOptions {
    var opts = NotifyOptions()
    var i = 0
    while i < args.count {
        let arg = args[i]
        func consumeValue() -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        switch arg {
        case "--id": opts.id = consumeValue()
        case "--source": opts.source = consumeValue()
        case "--kind": opts.kind = consumeValue()
        case "--title": opts.title = consumeValue()
        case "--body": opts.body = consumeValue()
        case "--url": opts.url = consumeValue()
        case "--low": opts.low = true
        default: break
        }
        i += 1
    }
    return opts
}

private func runNotify(_ args: [String]) {
    var opts = parseNotifyArgs(args)
    if opts.title == nil || opts.title?.isEmpty == true {
        opts.title = readLine(strippingNewline: true)
    }
    guard let title = opts.title, !title.isEmpty else {
        fail("inchill notify: no title given (pass --title, or pipe one in on stdin).")
    }

    var json: [String: Any] = ["title": title, "highSignal": !opts.low]
    if let id = opts.id { json["id"] = id }
    if let source = opts.source { json["source"] = source }
    if let kind = opts.kind { json["kind"] = kind }
    if let body = opts.body { json["body"] = body }
    if let url = opts.url { json["url"] = url }
    post(path: "/notify", json: json)
}

// MARK: - done / clear

private func runClear(id: String, source: String? = nil) {
    var json: [String: Any] = ["id": id]
    if let source { json["source"] = source }
    post(path: "/clear", json: json)
}

// MARK: - claude-hook

/// Claude Code's hook JSON on stdin. Only the fields this convention needs
/// are declared; other keys Claude Code sends are ignored.
/// Codex CLI and Gemini CLI send the same three fields under the same names
/// (`session_id`, `cwd`, `hook_event_name`), which is why one struct serves
/// all three harnesses. Only the *event names* differ, and those are mapped
/// to our four semantic arguments by the installer, not here.
private struct ClaudeHookPayload: Decodable {
    var session_id: String
    var cwd: String?
    var message: String?
    var hook_event_name: String?
    /// Available on `Stop` — the final assistant text, which makes a far
    /// better snippet than "Claude finished in <dir>" on its own.
    var last_assistant_message: String?
}

/// Where the session that fired this hook is actually running, captured from
/// the environment the hook inherits.
///
/// Opening the project folder was never what anyone wanted from a "Claude
/// needs you" item — you want the session. Two live cases, both answerable
/// here and nowhere else, because this process is the only part of the app
/// that runs *inside* the session:
///
/// - **Claude desktop app.** It exports `CLAUDE_CODE_HOST_SESSION_ID`
///   (`local_<uuid>`), which is the id its own UI addresses a session by.
/// - **A terminal.** The hook inherits the session's controlling terminal
///   even though its stdin is a pipe — a controlling terminal belongs to the
///   session, not to a file descriptor — so `/dev/tty` names the exact tab.
///
/// Everything here is best-effort and every field is optional: a hook that
/// can't tell where it is must still post the item.
private func sessionOrigin() -> [String: Any] {
    var origin: [String: Any] = [:]
    let env = ProcessInfo.processInfo.environment
    func put(_ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        origin[key] = value
    }
    put("host", env["CLAUDE_CODE_HOST_SESSION_ID"])
    put("entrypoint", env["CLAUDE_CODE_ENTRYPOINT"])
    put("termProgram", env["TERM_PROGRAM"])
    // Set by launchd for anything started as an app bundle and inherited all
    // the way down, so it names the terminal even when TERM_PROGRAM doesn't.
    put("bundleID", env["__CFBundleIdentifier"])
    put("tty", controllingTTY())
    return origin
}

/// The path of this process's controlling terminal, or nil when it has none
/// (a session run by the desktop app, a daemon, a CI job).
///
/// Two dead ends worth not re-walking, both of which *look* like they work:
/// `ttyname()` on the `/dev/tty` descriptor answers `/dev/tty`, and so does
/// `devname()` on that descriptor's device number — `/dev/tty` is a cloning
/// device, so its own identity is what you get back. `/dev/tty` matches no
/// terminal tab anywhere, so either would have made the jump silently
/// useless while looking correct in the payload.
///
/// The kernel's per-process controlling-terminal device (`e_tdev`) is the
/// real answer, and `devname()` turns that into `ttys004`. Reading fd 0/1/2
/// is no help either: the hook is fed JSON on stdin and its output is
/// captured, so none of them is a terminal.
private func controllingTTY() -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    let device = info.kp_eproc.e_tdev
    guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
    let path = "/dev/" + String(cString: name)
    return path == "/dev/tty" ? nil : path
}

private func runClaudeHook(
    _ rawEvent: String, harness: ClaudeHook.Harness = .claudeCode
) {
    let name = harness.subcommand
    guard let event = ClaudeHook.Event(rawValue: rawEvent) else {
        let known = ClaudeHook.Event.allCases.map(\.rawValue).joined(separator: "|")
        fail("inchill \(name): unknown hook kind '\(rawEvent)' (expected \(known)).")
    }
    guard let stdinData = try? FileHandle.standardInput.readToEnd(), !stdinData.isEmpty else {
        fail("inchill \(name): expected a JSON hook payload on stdin.")
    }
    guard let payload = try? JSONDecoder().decode(ClaudeHookPayload.self, from: stdinData) else {
        fail("inchill \(name): could not parse hook JSON from stdin.")
    }

    let request = ClaudeHook.request(
        for: event, sessionID: payload.session_id, cwd: payload.cwd,
        message: payload.message,
        lastAssistantMessage: payload.last_assistant_message,
        harness: harness)

    var json: [String: Any] = [
        "id": request.itemID, "source": harness.sourceName,
    ]
    if let title = request.title { json["title"] = title }
    if let kind = request.kind { json["kind"] = kind }
    if let body = request.body { json["body"] = body }
    if let highSignal = request.highSignal { json["highSignal"] = highSignal }
    if request.path == "/notify" {
        if let url = ClaudeHook.projectURL(for: payload.cwd) { json["url"] = url }
        let origin = sessionOrigin()
        if !origin.isEmpty { json["origin"] = origin }
    }

    // Best-effort: a queue that cannot be reached must not stall the session
    // that was only trying to tell it something. See `post(...)`.
    post(path: request.path, json: json, bestEffort: true)
}

// MARK: - Entry point

private let usage = """
    inchill — command-line companion for Inbox & Chill.

    Usage:
      inchill notify [--id X] [--source S] [--kind K] --title T [--body B] [--url U] [--low]
      inchill done <id>
      inchill clear <id>
      inchill claude-hook <notification|stop|user-prompt-submit|session-end>
      inchill codex-hook  <notification|stop|user-prompt-submit|session-end>
      inchill gemini-hook <notification|stop|user-prompt-submit|session-end>

    The *-hook sub-commands are driven by each agent's own config
    (~/.claude/settings.json, ~/.codex/hooks.json, ~/.gemini/settings.json —
    see the Terminal & Claude Code source in the app). They read a hook
    payload on stdin and keep exactly one queue row per session.
    """

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    fail(usage)
}

let command = arguments[1]
let rest = Array(arguments.dropFirst(2))

switch command {
case "notify":
    runNotify(rest)
case "done":
    guard let id = rest.first else { fail("inchill done: missing <id>.") }
    runClear(id: id)
case "clear":
    guard let id = rest.first else { fail("inchill clear: missing <id>.") }
    runClear(id: id)
// One sub-command per agent CLI. They share an implementation and a
// vocabulary — each harness's installer maps its own event names onto these
// four arguments — and differ only in the queue id prefix and the wording of
// a row, so a Codex session and a Claude Code session can never collide.
case _ where ClaudeHook.Harness.named(command) != nil:
    let harness = ClaudeHook.Harness.named(command)!
    guard let event = rest.first else {
        fail("inchill \(command): missing <\(ClaudeHook.Event.allCases.map(\.rawValue).joined(separator: "|"))>.")
    }
    runClaudeHook(event, harness: harness)
case "-h", "--help", "help":
    print(usage)
default:
    fail("inchill: unknown command '\(command)'.\n\n\(usage)")
}
