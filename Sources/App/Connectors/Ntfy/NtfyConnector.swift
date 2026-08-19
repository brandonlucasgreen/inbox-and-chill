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
    /// Non-secret half of basic auth; the password lives in the Keychain.
    private let username: String

    /// Last *message* id delivered — the reconnect cursor. Deliberately not
    /// updated for `open`/`keepalive` frames: those carry ids too, and using
    /// one as `since=` would skip every message published before it.
    private var lastMessageID: String?

    init(sourceID: String, server: String, topics: String, username: String = "") {
        self.sourceID = sourceID
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
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
        /// A publisher-defined action button. Only `view` carries somewhere
        /// to go; `http` and `broadcast` fire a request the app has no
        /// business making on a click, so they are ignored.
        struct Action: Decodable, Sendable {
            var action: String?
            var label: String?
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
        var actions: [Action]?
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
            url: link(for: frame),
            // The topic is the closest thing ntfy has to a channel, and one
            // source can subscribe to several — so it earns the actor slot.
            actorName: frame.topic?.nonEmptyOrNil,
            occurredAt: frame.time.map { Date(timeIntervalSince1970: $0) } ?? .now,
            highSignal: priority >= 4)
    }

    /// Where a click on this row should go, most explicit source first.
    ///
    /// ntfy has three structured places a publisher can put a destination —
    /// `click`, a `view` action, an attachment — and most publishers use
    /// none of them: the link is simply sitting in the message text, which
    /// left these rows as the only ones in the queue that did nothing when
    /// you pressed ⏎ on them. Reading the text is a guess, so it ranks below
    /// all three of the places that are not a guess.
    nonisolated static func link(for frame: Frame) -> String? {
        if let click = frame.click?.nonEmptyOrNil { return click }
        if let view = frame.actions?.first(where: {
            ($0.action ?? "view").lowercased() == "view"
                && $0.url?.nonEmptyOrNil != nil
        }) {
            return view.url?.nonEmptyOrNil
        }
        if let attachment = frame.attachment?.url?.nonEmptyOrNil {
            return attachment
        }
        return firstURL(in: frame.message) ?? firstURL(in: frame.title)
    }

    /// The first http(s) URL in a piece of text, or `nil`.
    ///
    /// `NSDataDetector` rather than a regex, because it already knows what a
    /// URL looks like at the end of a sentence — trailing full stops and
    /// closing brackets are exactly what hand-rolled patterns swallow.
    /// Restricted to http and https on purpose: the detector also matches
    /// bare hostnames and email addresses, and opening a mail composer
    /// because a message mentioned an address would be a surprise.
    nonisolated static func firstURL(in text: String?) -> String? {
        guard let text, !text.isEmpty,
            let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: String?
        detector.enumerateMatches(in: text, range: range) { match, _, stop in
            guard let url = match?.url,
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { return }
            found = url.absoluteString
            stop.pointee = true
        }
        return found
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

    /// Builds the `Authorization` header value, or `nil` for an unprotected
    /// topic (ntfy's default — no account needed).
    ///
    /// ntfy accepts either an access token as a bearer, or plain
    /// username/password as HTTP basic. A token wins when both are present:
    /// it's the narrower credential, and it's revocable without changing the
    /// account password.
    ///
    /// `nonisolated static` so the precedence rules are unit-testable without
    /// a Keychain or a socket.
    nonisolated static func authorizationHeader(
        token: String?, username: String?, password: String?
    ) -> String? {
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        {
            return "Bearer \(token)"
        }
        // Basic auth needs both halves; half a credential is a
        // misconfiguration, and sending it would just 401.
        guard
            let user = username?.trimmingCharacters(in: .whitespacesAndNewlines),
            !user.isEmpty,
            let pass = password, !pass.isEmpty
        else { return nil }

        let encoded = Data("\(user):\(pass)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    /// Classifies a dropped/refused socket. Anything transient reads as
    /// reconnecting, but a credential or address problem must not: ntfy
    /// answers **401 even for a topic that works anonymously** when the
    /// credentials it was handed are wrong, so a typo'd password would
    /// otherwise sit in "connecting…" forever while quietly never delivering.
    ///
    /// `nonisolated static` to keep it testable without a socket.
    nonisolated static func status(forHTTPStatus code: Int?) -> ConnectorStatus {
        switch code {
        case 401:
            return .error(
                "ntfy rejected the credentials (401). Check the token, or the username and password — note that ntfy also returns 401 on an otherwise-public topic when the credentials sent are wrong, so clearing them entirely is the fix if the topic needs no account."
            )
        case 403:
            return .error(
                "ntfy refused access to this topic (403). The account authenticated, but isn't allowed to read it."
            )
        case 404:
            return .error(
                "ntfy returned 404 — check the server URL and topic name (a self-hosted instance behind a subpath needs that path included)."
            )
        default:
            // Network blips, server restarts, sleep/wake: the SyncEngine
            // restarts us and we resume from `lastMessageID`.
            return .connecting
        }
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
        // that can't set headers, and would put the credential in the URL.
        if let header = Self.authorizationHeader(
            token: Keychain.get("\(sourceID).token"),
            username: username,
            password: Keychain.get("\(sourceID).password"))
        {
            request.setValue(header, forHTTPHeaderField: "Authorization")
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
            let httpStatus = (socket.response as? HTTPURLResponse)?.statusCode
            emit(.status(Self.status(forHTTPStatus: httpStatus)))
        }
    }
}

extension String {
    /// `nil` rather than `""`, so optional-chaining a blank JSON field falls
    /// through to the next candidate.
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
