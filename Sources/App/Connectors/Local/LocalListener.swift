import Foundation
import Network
import Security

/// Runs a closure exactly once, even if invoked concurrently. `NWListener`'s
/// `stateUpdateHandler` is a plain (non-actor-isolated) `@Sendable` closure,
/// so the one-shot "resume this continuation on the first ready/failed
/// state" guard needs its own synchronization rather than a captured `var`.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasRun else { return }
        hasRun = true
        body()
    }
}

/// A tiny localhost-only HTTP server that lets same-machine producers (the
/// `inchill` CLI, Claude Code hooks) push items into the triage queue without
/// any of Slack/Linear/GitHub's remote-auth machinery.
///
/// Discovery contract: on every successful start, this writes
/// `~/Library/Application Support/InboxAndChill/local-api.json` —
/// `{"port": <ephemeral port>, "token": "<64-char hex bearer token>"}` — with
/// POSIX permissions `0600`. This file *is* the handshake: `inchill` reads it
/// to learn where we're listening and what bearer token to send. If the file
/// is missing or stale (app not running), the CLI fails fast rather than
/// guessing a port.
///
/// Protocol: plain HTTP/1.1 over TCP, one request per connection.
///   - `Authorization: Bearer <token>` is required on every request; anything
///     else (missing, wrong token) gets `401`.
///   - `POST /notify` `{id?, source?, kind?, title, body?, url?, highSignal?}`
///     → `200 {"ok":true}`.
///   - `POST /clear` `{id, source?}` → `200 {"ok":true}`.
///   - Anything else → `404`.
///   - Every response includes `Connection: close`; we always close the
///     socket after replying (requests are tiny, single-shot JSON posts —
///     no keep-alive, no pipelining, no chunked bodies).
actor LocalListener {
    static let shared = LocalListener()

    /// Decoded body of `POST /notify`.
    struct NotifyPayload: Decodable, Sendable {
        var id: String?
        var source: String?
        var kind: String?
        var title: String
        var body: String?
        var url: String?
        var highSignal: Bool?
    }

    /// Decoded body of `POST /clear`.
    struct ClearPayload: Decodable, Sendable {
        var id: String
        var source: String?
    }

    private struct LocalAPIInfo: Codable {
        var port: Int
        var token: String
    }

    private struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    enum ListenerError: LocalizedError, CustomStringConvertible {
        case noAssignedPort

        var errorDescription: String? {
            switch self {
            case .noAssignedPort:
                return "LocalListener: NWListener became ready without an assigned port."
            }
        }
        var description: String { errorDescription ?? "LocalListener error" }
    }

    private static let infoFileURL = URL.applicationSupportDirectory
        .appending(path: "InboxAndChill/local-api.json")

    private let queue = DispatchQueue(label: "lol.bgreen.inboxandchill.local-listener")

    private var listener: NWListener?
    private var token: String = ""
    private var port: UInt16 = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var onNotify: (@Sendable (NotifyPayload) -> Void)?
    private var onClear: (@Sendable (ClearPayload) -> Void)?

    /// Bumped on every successful listener bind. `stop(generation:)` only
    /// tears down when the caller's token still matches, so a restarting
    /// `LocalConnector` can't have its outgoing task dismantle its incoming
    /// task's listener.
    private var generation: UInt64 = 0

    /// Starts the listener if it isn't already running (idempotent — safe to
    /// call every time a connector registers). Handlers are updated on every
    /// call so the most recent caller "wins," which is fine: only
    /// `LocalConnector` ever calls this.
    ///
    /// Returns a generation token the caller must hand back to
    /// `stop(generation:)`. Without it, a `LocalConnector` restart is a race:
    /// SyncEngine's new task can `start()` before the cancelled task's
    /// `stop()` runs, and an ungated `stop()` would then cancel the *new*
    /// listener while the discovery file still advertised its port — leaving
    /// every `inchill` call (and so every Claude Code hook) failing to
    /// connect until the app was relaunched.
    @discardableResult
    func start(
        onNotify: @escaping @Sendable (NotifyPayload) -> Void,
        onClear: @escaping @Sendable (ClearPayload) -> Void
    ) async throws -> UInt64 {
        self.onNotify = onNotify
        self.onClear = onClear
        if listener != nil {
            // Already bound: adopt the new handlers and re-assert the
            // discovery file in case a previous stop removed it.
            try? writeInfoFile()
            return generation
        }

        // Fresh token on every listener start (i.e. every app launch): the
        // CLI re-reads the discovery file per invocation, so rotation is
        // free — and it caps the useful life of a leaked token at one
        // app session.
        token = Self.randomToken()

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: .any)

        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeOnce = ResumeOnce()
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce.run { continuation.resume() }
                case .failed(let error):
                    resumeOnce.run { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            newListener.start(queue: queue)
        }

        guard let assignedPort = newListener.port else {
            newListener.cancel()
            throw ListenerError.noAssignedPort
        }

        listener = newListener
        port = assignedPort.rawValue
        generation += 1
        try writeInfoFile()
        return generation
    }

    /// Stops the listener and drops all in-flight connections. Called when
    /// the owning `LocalConnector`'s task is cancelled.
    ///
    /// A stale token means another `start()` has since taken ownership, so
    /// this is a late teardown from a task that no longer owns the listener —
    /// ignore it rather than killing a live listener.
    func stop(generation epoch: UInt64) {
        // Note: named `epoch`, not `token` — `token` is the bearer-token
        // property, and shadowing it here would be a trap for the next reader.
        guard epoch == generation, listener != nil else { return }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = 0
        for (_, connection) in connections { connection.cancel() }
        connections.removeAll()
        // Remove the handshake file rather than leave it pointing at a dead
        // port: `inchill` then reports "Inbox & Chill isn't running" instead
        // of a confusing connection failure.
        try? FileManager.default.removeItem(at: Self.infoFileURL)
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func drop(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.handleReceive(
                    data: data, isComplete: isComplete, error: error,
                    connection: connection, buffer: buffer)
            }
        }
    }

    private func handleReceive(
        data: Data?, isComplete: Bool, error: NWError?,
        connection: NWConnection, buffer: Data
    ) async {
        var buffer = buffer
        if let data, !data.isEmpty { buffer.append(data) }

        if let request = Self.parseRequest(buffer) {
            await respond(to: request, on: connection)
            return
        }

        // Requests here are tiny single-read JSON posts; anything that
        // hasn't resolved into a full request within 1MB or that the peer
        // has already closed is malformed — give up rather than buffer
        // forever.
        if isComplete || error != nil || buffer.count > 1_048_576 {
            drop(connection)
            return
        }

        receiveRequest(on: connection, buffer: buffer)
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        guard !token.isEmpty, request.headers["authorization"] == "Bearer \(token)" else {
            send(status: 401, statusText: "Unauthorized", json: #"{"error":"unauthorized"}"#, on: connection)
            return
        }

        switch (request.method.uppercased(), request.path) {
        case ("POST", "/notify"):
            guard let payload = try? JSONDecoder().decode(NotifyPayload.self, from: request.body) else {
                send(status: 400, statusText: "Bad Request", json: #"{"error":"invalid JSON body"}"#, on: connection)
                return
            }
            onNotify?(payload)
            send(status: 200, statusText: "OK", json: #"{"ok":true}"#, on: connection)

        case ("POST", "/clear"):
            guard let payload = try? JSONDecoder().decode(ClearPayload.self, from: request.body) else {
                send(status: 400, statusText: "Bad Request", json: #"{"error":"invalid JSON body"}"#, on: connection)
                return
            }
            onClear?(payload)
            send(status: 200, statusText: "OK", json: #"{"ok":true}"#, on: connection)

        default:
            send(status: 404, statusText: "Not Found", json: #"{"error":"not found"}"#, on: connection)
        }
    }

    private func send(status: Int, statusText: String, json: String, on connection: NWConnection) {
        let response =
            "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(json.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + json
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { [weak self] _ in
                Task { await self?.drop(connection) }
            })
    }

    // MARK: - Minimal HTTP parsing

    /// Accumulate-until-`\r\n\r\n` + `Content-Length` parser. Returns `nil`
    /// until a complete request (headers + full body) has arrived.
    private static func parseRequest(_ buffer: Data) -> HTTPRequest? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: terminator) else { return nil }
        guard let headerString = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return nil }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        return HTTPRequest(
            method: method, path: path, headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd]))
    }

    // MARK: - Token + discovery file

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed unexpectedly")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func writeInfoFile() throws {
        let dir = Self.infoFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info = LocalAPIInfo(port: Int(port), token: token)
        let data = try JSONEncoder().encode(info)
        // createFile applies the permissions atomically with creation —
        // write-then-chmod would leave a default-umask window where another
        // local user could read the token.
        try? FileManager.default.removeItem(at: Self.infoFileURL)
        guard FileManager.default.createFile(
            atPath: Self.infoFileURL.path, contents: data,
            attributes: [.posixPermissions: 0o600])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
