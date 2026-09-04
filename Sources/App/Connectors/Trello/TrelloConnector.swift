import Foundation

/// Polls Trello's notification feed, which is a real per-user inbox with
/// two-way read state — the same shape as Linear and GitLab, and rarer than
/// it sounds (Jira and Asana have no such endpoint at all).
///
/// `GET /1/members/me/notifications?read_filter=unread` is the queue and
/// `PUT /1/notifications/{id}?unread=false` clears one, so `E` writes through
/// and `.remoteTruth` archives anything read in Trello itself.
///
/// **Written against Trello's published spec, never against a live account**
/// (2026-09-04 — Brandon has none). The mapping helpers are pure and tested
/// against the documented payload; the failure paths are pinned just as hard,
/// because they are the half nobody can watch happen.
///
/// Two things were verified live without an account, and both shaped the code:
///
/// - **Trello answers in plain text, not JSON.** A bad key returns
///   **401 `invalid key`**; missing credentials return **400 `invalid
///   token`**. So `explain` reads the body rather than the status alone, and
///   can name *which* of the two values is wrong — which matters because this
///   is the only source in the app asking for two.
/// - **Credentials travel in the query string** (the spec's own security
///   scheme is `apiKey` in `query`), not a header. Nothing here may ever
///   interpolate a request URL into an error or a log line; `ProblemLog`
///   would keep the token on disk. Every message below is built from the
///   status and body only.
actor TrelloConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "trello"
    nonisolated let capabilities: ConnectorCapabilities = [
        .markDone, .remoteTruth,
    ]
    nonisolated let pollInterval: TimeInterval = 60

    private var snapshotComplete = true

    /// Trello's own maximum is 1,000 per page, but a page of 100 keeps one
    /// slow response from being a big one; 10 pages is the same 1,000 ceiling
    /// GitHub and GitLab use. `page` is **0-based** here, unlike GitLab's.
    static let perPage = 100
    static let maxPages = 10
    static let host = "https://api.trello.com"

    // MARK: Credentials

    /// The key is *not* secret and the token is.
    ///
    /// Trello's own documentation says the API key "is intended to be
    /// publicly accessible" while the token "should be kept secret" — it
    /// grants full account access. So the key lives in the source's settings
    /// and only the token goes to the Keychain, which is Trello's model
    /// rather than ours imposed on it.
    private func credentials() throws -> (key: String, token: String) {
        guard let key = storedKey else {
            throw TrelloError(
                errorDescription:
                    "Trello: no API key configured for this source.")
        }
        guard let token = Keychain.get("\(sourceID).token")?.nonEmpty else {
            throw TrelloError(
                errorDescription:
                    "Trello: no token configured for this source. The API key alone can't read your notifications.")
        }
        return (key, token)
    }

    /// From the source's settings rather than the Keychain, because the key
    /// is not a secret (see `credentials()`).
    private let storedKey: String?

    init(sourceID: String = "trello", apiKey: String = "") {
        self.sourceID = sourceID
        self.storedKey = apiKey.nonEmpty
    }

    // MARK: Fetch

    func fetch() async throws -> [RemoteItem] {
        let (key, token) = try credentials()
        var collected: [RemoteItem] = []
        var complete = true

        for page in 0..<Self.maxPages {
            let notifications = try await fetchPage(
                page: page, key: key, token: token)
            collected.append(contentsOf: notifications.map(Self.item(from:)))
            guard notifications.count >= Self.perPage else { break }
            if page == Self.maxPages - 1 { complete = false }
        }

        snapshotComplete = complete
        return collected
    }

    func snapshotWasComplete() async -> Bool { snapshotComplete }

    private func fetchPage(
        page: Int, key: String, token: String
    ) async throws -> [Notification] {
        var components = URLComponents(
            string: "\(Self.host)/1/members/me/notifications")!
        components.queryItems = [
            URLQueryItem(name: "read_filter", value: "unread"),
            URLQueryItem(name: "limit", value: String(Self.perPage)),
            URLQueryItem(name: "page", value: String(page)),
            // Without this the response carries no author, and every row
            // would lose the one fact that says who wants you.
            URLQueryItem(name: "memberCreator", value: "true"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = components.url else {
            throw TrelloError(
                errorDescription: "Trello: couldn't build a request URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrelloError(
                errorDescription:
                    "Trello: non-HTTP response from the notifications endpoint.")
        }
        guard http.statusCode == 200 else {
            throw TrelloError(
                errorDescription: Self.explain(
                    status: http.statusCode, body: data, writing: false))
        }
        return try JSONDecoder().decode([Notification].self, from: data)
    }

    // MARK: Write-back

    /// `E` marks the notification read in Trello, so it leaves the unread
    /// feed and stops arriving. A 404 is treated as success: the
    /// notification is already gone, and erroring would put a red dot on the
    /// source for obeying twice.
    func markDone(externalID: String, payload: Data?) async throws {
        let (key, token) = try credentials()
        var components = URLComponents(
            string: "\(Self.host)/1/notifications/\(externalID)")!
        components.queryItems = [
            URLQueryItem(name: "unread", value: "false"),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "token", value: token),
        ]
        guard let url = components.url else {
            throw TrelloError(
                errorDescription:
                    "Trello: couldn't build a request URL to mark \(externalID) read.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrelloError(
                errorDescription:
                    "Trello: non-HTTP response marking notification \(externalID) read.")
        }
        guard !(200...204).contains(http.statusCode), http.statusCode != 404
        else { return }
        throw TrelloError(
            errorDescription: Self.explain(
                status: http.statusCode, body: data, writing: true))
    }

    // MARK: Decoding

    /// The notification shape, decoded leniently on purpose.
    ///
    /// **Trello's own spec types `data` as a string with a null example,
    /// which is wrong** — in a real response it is an object holding the
    /// card, the board and (for a comment) the text. Since there is no
    /// account here to settle it, both shapes are accepted: the nested
    /// `data.card` / `data.board` *and* the top-level `card` / `board` the
    /// spec's schema describes. Whichever arrives is used, and neither being
    /// present costs the row its link, not the row.
    struct Notification: Decodable, Sendable {
        struct Entity: Decodable, Sendable {
            var id: String?
            var name: String?
            /// The slug in `trello.com/c/<shortLink>`.
            var shortLink: String?
        }
        struct Payload: Decodable, Sendable {
            var text: String?
            var card: Entity?
            var board: Entity?
            var list: Entity?
        }
        struct Member: Decodable, Sendable {
            var fullName: String?
            var username: String?
        }
        var id: String
        var type: String
        var date: String
        var unread: Bool?
        var data: Payload?
        var card: Entity?
        var board: Entity?
        var memberCreator: Member?
    }

    // MARK: Mapping (pure — rule 6)

    nonisolated static func item(from notification: Notification) -> RemoteItem {
        let grouping = grouping(for: notification)
        return RemoteItem(
            externalID: notification.id,
            kind: notification.type,
            title: title(for: notification),
            snippet: snippet(for: notification),
            url: link(for: notification),
            actorName: notification.memberCreator?.fullName?.nonEmpty
                ?? notification.memberCreator?.username?.nonEmpty,
            // `.distantPast`, never `.now`: a `.now` fallback beats every
            // `doneAt`, so `Store.resurrectIfNeeded` would revive the row on
            // the next poll and it could never be dismissed.
            occurredAt: ISO8601Timestamp.date(from: notification.date)
                ?? .distantPast,
            highSignal: isHighSignal(type: notification.type),
            groupKey: grouping?.key,
            groupLabel: grouping?.label)
    }

    /// "Mentioned you: Fix the onboarding flow".
    nonisolated static func title(for notification: Notification) -> String {
        let action = humanize(type: notification.type)
        guard let subject = card(in: notification)?.name?.nonEmpty
            ?? board(in: notification)?.name?.nonEmpty
        else { return action }
        return "\(action): \(subject)"
    }

    /// The comment text when there is one — that is what `D` exists to
    /// reveal — else the board name, so a row still says where it happened.
    nonisolated static func snippet(for notification: Notification) -> String? {
        if let text = notification.data?.text?.nonEmpty { return text }
        return board(in: notification)?.name?.nonEmpty
    }

    /// Trello notifications carry no URL, so the card's short link is built
    /// into one. A board-level notification lands on the board instead.
    nonisolated static func link(for notification: Notification) -> String? {
        if let card = card(in: notification)?.shortLink?.nonEmpty {
            return "https://trello.com/c/\(card)"
        }
        if let board = board(in: notification)?.shortLink?.nonEmpty {
            return "https://trello.com/b/\(board)"
        }
        return nil
    }

    /// Folds by board — the id is stable across renames, the name reads.
    nonisolated static func grouping(
        for notification: Notification
    ) -> (key: String, label: String)? {
        guard let board = board(in: notification),
            let id = board.id?.nonEmpty
        else { return nil }
        return (id, board.name?.nonEmpty ?? "Trello board")
    }

    /// Nested first, top-level second — see `Notification`.
    nonisolated static func card(
        in notification: Notification
    ) -> Notification.Entity? {
        notification.data?.card ?? notification.card
    }

    nonisolated static func board(
        in notification: Notification
    ) -> Notification.Entity? {
        notification.data?.board ?? notification.board
    }

    /// Types where a person is waiting on you.
    ///
    /// `commentCard` is deliberately **out**, matching the line
    /// `GitHubConnector` draws by excluding its `comment` reason: a comment
    /// on a card you are on is worth reading, not worth a badge. `cardDueSoon`
    /// is **in** — Trello only sends it for a card you are a member of, so it
    /// is a commitment of yours coming due, which is the same call Brandon
    /// made for overdue reminders.
    nonisolated static let highSignalTypes: Set<String> = [
        "mentionedOnCard", "addedToCard", "addedMemberToCard", "addedToBoard",
        "invitedToBoard", "makeAdminOfBoard", "cardDueSoon",
        "addedToOrganization", "makeAdminOfOrganization",
    ]

    nonisolated static func isHighSignal(type: String) -> Bool {
        highSignalTypes.contains(type)
    }

    /// Trello's action-type names as sentences. An unknown type is split on
    /// its camel humps rather than dropped, so a type Trello adds later reads
    /// as "Added label to card" instead of `addedLabelToCard`.
    nonisolated static func humanize(type: String) -> String {
        switch type {
        case "mentionedOnCard": return "Mentioned you"
        case "commentCard": return "New comment"
        case "addedToCard", "addedMemberToCard": return "Added you to a card"
        case "removedFromCard", "removedMemberFromCard":
            return "Removed you from a card"
        case "cardDueSoon": return "Due soon"
        case "addedToBoard": return "Added you to a board"
        case "invitedToBoard": return "Invited you to a board"
        case "makeAdminOfBoard": return "Made you a board admin"
        case "addedToOrganization": return "Added you to a workspace"
        case "makeAdminOfOrganization": return "Made you a workspace admin"
        case "changeCard": return "Card changed"
        case "createdCard": return "Card created"
        case "addAttachmentToCard": return "Attachment added"
        case "updateCheckItemStateOnCard": return "Checklist item updated"
        case "closeBoard": return "Board closed"
        default: return splitCamelCase(type)
        }
    }

    nonisolated static func splitCamelCase(_ raw: String) -> String {
        var words = ""
        for character in raw {
            if character.isUppercase, !words.isEmpty {
                words.append(" ")
                words.append(Character(character.lowercased()))
            } else {
                words.append(character)
            }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Failures (rule 5)

    /// Trello's error bodies are **plain text**, verified live: a bad key is
    /// `401 invalid key`, absent credentials are `400 invalid token`. This is
    /// the only source asking for two values, so naming which one is wrong is
    /// the difference between a fix and a guess.
    ///
    /// The request URL is never included: the key and token ride in the query
    /// string, and this sentence ends up in `ProblemLog` on disk.
    nonisolated static func explain(
        status: Int, body: Data, writing: Bool
    ) -> String {
        let text =
            (String(data: body.prefix(200), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        let action = writing ? "marking a notification read" : "reading your notifications"

        if lowered.contains("invalid key") {
            return
                "Trello rejected the API key while \(action). Check the key on the Power-Up's API Key tab — it is the short public one, not the token."
        }
        if lowered.contains("invalid token") || lowered.contains("expired token") {
            return
                "Trello rejected the token while \(action). Generate a new one from the Token link beside your API key; a token can also be revoked from your Trello account settings."
        }
        switch status {
        case 401:
            return
                "Trello refused the request (401) while \(action). \(detail(text))"
        case 400:
            return
                "Trello rejected the request (400) while \(action). \(detail(text))"
        case 429:
            return
                "Trello is rate-limiting this source (429). It will try again on the next poll."
        case 500...599:
            return
                "Trello returned a server error (\(status)) while \(action). Nothing is wrong with your setup; it will retry."
        default:
            return
                "Trello returned an unexpected status (\(status)) while \(action). \(detail(text))"
        }
    }

    private nonisolated static func detail(_ text: String) -> String {
        text.isEmpty ? "Trello sent no explanation." : "Trello said: \(text)"
    }

    struct TrelloError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        var description: String { errorDescription ?? "Trello connector error" }
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
