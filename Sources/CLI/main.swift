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
//   inchill claude-hook <notification|stop>

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

@discardableResult
private func post(path: String, json: [String: Any]) -> Bool {
    guard let info = loadLocalAPIInfo() else {
        fail("Inbox & Chill isn't running (or local sources are off).")
    }
    guard let url = URL(string: "http://127.0.0.1:\(info.port)\(path)") else {
        fail("inchill: could not construct request URL for \(path).")
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
        fail("inchill: timed out waiting for Inbox & Chill to respond.")
    }
    if let failureMessage = outcome.failureMessage {
        fail(failureMessage)
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
private struct ClaudeHookPayload: Decodable {
    var session_id: String
    var cwd: String?
    var message: String?
    var hook_event_name: String?
    /// Available on `Stop` — the final assistant text, which makes a far
    /// better snippet than "Claude finished in <dir>" on its own.
    var last_assistant_message: String?
}

/// A `file://` URL for the session's working directory.
///
/// Claude Code publishes no way to deep-link to a specific session — there is
/// no documented URL scheme and no resume-by-id URI — so the project folder is
/// the closest addressable thing, and it at least makes ⏎ on the item land you
/// in the right project rather than nowhere.
private func projectURL(for cwd: String?) -> String? {
    guard let cwd, !cwd.isEmpty else { return nil }
    return URL(fileURLWithPath: cwd).absoluteString
}

/// First non-empty line, trimmed to something that fits a queue row.
private func firstLine(of text: String?, limit: Int = 200) -> String? {
    guard let text else { return nil }
    guard
        let line = text.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
    else { return nil }
    return line.count > limit ? String(line.prefix(limit)) + "…" : line
}

private func runClaudeHook(_ kind: String) {
    guard let stdinData = try? FileHandle.standardInput.readToEnd(), !stdinData.isEmpty else {
        fail("inchill claude-hook: expected a JSON hook payload on stdin.")
    }
    guard let payload = try? JSONDecoder().decode(ClaudeHookPayload.self, from: stdinData) else {
        fail("inchill claude-hook: could not parse hook JSON from stdin.")
    }

    switch kind {
    case "notification":
        // A session wants the user: permission prompt or idle-waiting.
        // Always high-signal, auto-clears when the wait ends (see "stop").
        let title = (payload.message?.isEmpty == false) ? payload.message! : "Claude Code needs your input"
        let cwdBase = payload.cwd.map { ($0 as NSString).lastPathComponent } ?? "unknown"
        var json: [String: Any] = [
            "id": "claude-\(payload.session_id)",
            "source": "claude-code",
            "kind": "claude_waiting",
            "title": title,
            "body": "in \(cwdBase)",
            "highSignal": true,
        ]
        if let url = projectURL(for: payload.cwd) { json["url"] = url }
        post(path: "/notify", json: json)

    case "stop":
        // The turn ended: clear the waiting item (if any) and leave a
        // low-signal "done" breadcrumb so a finished-but-unattended session
        // still surfaces in the queue.
        runClear(id: "claude-\(payload.session_id)", source: "claude-code")

        let cwdBase = payload.cwd.map { ($0 as NSString).lastPathComponent } ?? "unknown"
        let timestamp = Int(Date().timeIntervalSince1970)
        var json: [String: Any] = [
            "id": "claude-done-\(payload.session_id)-\(timestamp)",
            "source": "claude-code",
            "kind": "claude_done",
            "title": "Claude finished in \(cwdBase)",
            "highSignal": false,
        ]
        // What it actually said beats a bare "finished" when you're scanning
        // several sessions at once.
        if let summary = firstLine(of: payload.last_assistant_message) {
            json["body"] = summary
        }
        if let url = projectURL(for: payload.cwd) { json["url"] = url }
        post(path: "/notify", json: json)

    default:
        fail("inchill claude-hook: unknown hook kind '\(kind)' (expected 'notification' or 'stop').")
    }
}

// MARK: - Entry point

private let usage = """
    inchill — command-line companion for Inbox & Chill.

    Usage:
      inchill notify [--id X] [--source S] [--kind K] --title T [--body B] [--url U] [--low]
      inchill done <id>
      inchill clear <id>
      inchill claude-hook <notification|stop>
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
case "claude-hook":
    guard let kind = rest.first else { fail("inchill claude-hook: missing <notification|stop>.") }
    runClaudeHook(kind)
case "-h", "--help", "help":
    print(usage)
default:
    fail("inchill: unknown command '\(command)'.\n\n\(usage)")
}
