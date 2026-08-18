import Foundation

/// Push connector for [ntfy](https://ntfy.sh) — hosted or self-hosted.
///
/// Subscribes to `<server>/<topics>/ws` and turns each published message into
/// a queue item. Of every connector here this is the least ceremonious: no
/// OAuth (ntfy has none to offer), no app registration, one optional token,
/// and the server keeps a message cache so a dropped connection can be
/// resumed without losing anything.
///
/// **No `.remoteTruth`.** An ntfy message is a fire-and-forget event, not a
/// row in a remote inbox — there is no read-state to diff a snapshot against.
/// Items therefore die only by explicit done, exactly like `LocalConnector`.
///
/// **Replay contract.** `since=` accepts a message id, so on every reconnect
/// we resume from the last message we actually delivered and lose nothing in
/// the gap. On a cold start there is no cursor, so we take a bounded window
/// (`coldStartWindow`) rather than `since=all`, which on a long-retention
/// self-hosted instance could mean thousands of messages. Replay is safe to
/// repeat: items are keyed on the ntfy message id, and the Store leaves an
/// already-done item done unless the remote timestamp moved on.
actor NtfyConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "ntfy"
    nonisolated let capabilities: ConnectorCapabilities = [.push]

    /// How far back a cold start reaches. ntfy accepts a duration string here.
    private static let coldStartWindow = "12h"

    private let server: String
    private let topics: String

    /// Last *message* id delivered — the reconnect cursor. Deliberately not
    /// updated for `open`/`keepalive` frames: those carry ids too, and using
    /// one as `since=` would skip every message published before it.
    private var lastMessageID: String?

    init(sourceID: String, server: String, topics: String) {
        self.sourceID = sourceID
        self.server =
            server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://ntfy.sh"
            : server.trimmingCharacters(in: .whitespacesAndNewlines)
        self.topics = topics
    }

    func fetch() async throws -> [RemoteItem] { [] }

    // MARK: - Wire format

    /// One frame off the socket. ntfy multiplexes control frames and real
    /// messages down the same connection, discriminated by `event`.
    struct Frame: Decodable, Sendable {
        struct Attachment: Decodable, Sendable {
            var name: String?
            var url: String?
        }
        var id: String
        var time: Double?
        var event: String?
        var topic: String?
        var title: String?
        var message: String?
        var priority: Int?
        var tags: [String]?
        var click: String?
        var attachment: Attachment?
    }

    /// Builds the item a message frame becomes, or `nil` if the frame isn't a
    /// message (or carries no displayable text at all).
    ///
    /// `nonisolated` and `static` so the mapping is unit-testable without
    /// standing up a socket.
    nonisolated static func item(from frame: Frame) -> RemoteItem? {
        // A missing `event` is a message: ntfy omits it on some publish paths,
        // and only control frames name themselves.
        let event = frame.event ?? "message"
        guard event == "message" else { return nil }

        let body = frame.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil
        let explicitTitle = frame.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil
        // ntfy's title is optional. With no title the body *is* the headline —
        // and must then not be repeated into the snippet.
        guard let title = explicitTitle ?? body else { return nil }
        let snippet = explicitTitle == nil ? nil : body

        // ntfy priority runs 1...5 with 3 as the default; 4 (high) and
        // 5 (max) are the ones the user asked to be interrupted for.
        let priority = frame.priority ?? 3

        return RemoteItem(
            externalID: frame.id,
            kind: "ntfy_message",
            title: title,
            snippet: snippet,
            url: frame.click?.nonEmptyOrNil ?? frame.attachment?.url?.nonEmptyOrNil,
            // The topic is the closest thing ntfy has to a channel, and one
            // source can subscribe to several — so it earns the actor slot.
            actorName: frame.topic?.nonEmptyOrNil,
            occurredAt: frame.time.map { Date(timeIntervalSince1970: $0) } ?? .now,
            highSignal: priority >= 4)
    }

    // MARK: - URL construction

    /// `https://ntfy.sh` + topics → `wss://ntfy.sh/<topics>/ws?since=…`.
    ///
    /// `nonisolated` and `static` for the same testability reason as `item`.
    nonisolated static func socketURL(
        server: String, topics: String, since: String?
    ) -> URL? {
        guard var components = URLComponents(string: server) else { return nil }

        // ntfy is documented with http(s) URLs; the socket lives at the same
        // host under the ws(s) scheme.
        switch components.scheme?.lowercased() {
        case "https", "wss", nil: components.scheme = "wss"
        case "http", "ws": components.scheme = "ws"
        default: return nil
        }

        let list =
            topics
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !list.isEmpty else { return nil }

        // Preserve any base path (self-hosted instances behind a subpath).
        let base = components.path.hasSuffix("/")
            ? String(components.path.dropLast()) : components.path
        components.path = "\(base)/\(list.joined(separator: ","))/ws"
        if let since { components.queryItems = [URLQueryItem(name: "since", value: since)] }
        return components.url
    }

    private func makeRequest() -> URLRequest? {
        guard
            let url = Self.socketURL(
                server: server, topics: topics,
                since: lastMessageID ?? Self.coldStartWindow)
        else { return nil }

        var request = URLRequest(url: url)
        // Optional: only protected topics need it. Sent as a header rather
        // than ntfy's `?auth=` query param — that form exists for browsers
        // that can't set headers, and would put the token in the URL.
        if let token = Keychain.get("\(sourceID).token"), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Run loop

    func run(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {
        emit(.status(.connecting))

        guard let request = makeRequest() else {
            emit(
                .status(
                    .error(
                        "ntfy: couldn't build a subscription URL from server “\(server)” and topics “\(topics)”."
                    )))
            return
        }

        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        do {
            while !Task.isCancelled {
                // `receive()` isn't cancellation-aware, so a pending read
                // would pin this task alive until ntfy next sent something.
                // Closing the socket on cancel makes the read fail promptly.
                let message = try await withTaskCancellationHandler {
                    try await socket.receive()
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }

                let data: Data
                switch message {
                case .data(let payload): data = payload
                case .string(let text): data = Data(text.utf8)
                @unknown default: continue
                }

                guard let frame = try? JSONDecoder().decode(Frame.self, from: data)
                else { continue }

                // `open` is ntfy's handshake — the first thing a healthy
                // subscription sends, so it's what flips the status dot green.
                if frame.event == "open" {
                    emit(.status(.ok(.now)))
                    continue
                }
                guard let item = Self.item(from: frame) else { continue }
                lastMessageID = frame.id
                emit(.upsert([item]))
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            // The SyncEngine restarts push connectors after a short backoff,
            // and we'll resume from `lastMessageID` — so a dropped socket is
            // reconnecting, not broken.
            emit(.status(.connecting))
        }
    }
}

extension String {
    /// `nil` rather than `""`, so optional-chaining a blank JSON field falls
    /// through to the next candidate.
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
