import Foundation

/// Polls Sentry's organization issues endpoint. Sentry's own "For Review"
/// concept is already a triage queue, so the default query is literally it —
/// `is:unresolved is:for_review` with `sort=inbox`.
///
/// **Why "done" is local by default.** Resolving a Sentry issue is a
/// team-visible action: it closes the issue for everyone and Sentry will
/// re-open it if the error recurs. Dismissing a row here means "I've seen
/// this", which is not the same claim. So the connector ships with
/// `.remoteTruth` but *without* `.markDone`, and relies on the resurrect
/// rule instead: the item stays done until `lastSeen` moves past `doneAt`,
/// i.e. until the error actually happens again. That is the behaviour you
/// want from an error tracker. Turning on "Resolve in Sentry" opts into the
/// stronger, shared meaning.
///
/// The whole reason that works is `occurredAt` being the real event time —
/// see `parseTimestamp`, which exists because Sentry's timestamps carry
/// fractional seconds and `ISO8601DateFormatter`'s two option sets are
/// mutually exclusive.
actor SentryConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "sentry"
    nonisolated let capabilities: ConnectorCapabilities
    nonisolated let pollInterval: TimeInterval = 60

    private let org: String
    private let query: String
    private let resolveOnDone: Bool

    /// Sentry caps `limit` at 100 and pages by opaque cursor from the `Link`
    /// header. 10 × 100 = 1,000 issues; past that we report the snapshot
    /// incomplete rather than let `.remoteTruth` archive the tail — the same
    /// trap `GitHubConnector` documents.
    static let perPage = 100
    static let maxPages = 10

    private var snapshotComplete = true

    init(
        sourceID: String, org: String, query: String, resolveOnDone: Bool
    ) {
        self.sourceID = sourceID
        self.org = org.trimmingCharacters(in: .whitespaces)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        self.query = trimmed.isEmpty ? Self.defaultQuery : trimmed
        self.resolveOnDone = resolveOnDone
        self.capabilities =
            resolveOnDone
            ? [.remoteTruth, .markDone, .providesContext]
            : [.remoteTruth, .providesContext]
    }

    /// Sentry's "For Review" tab, which is the closest thing it has to an
    /// inbox: unresolved issues nobody has triaged yet.
    static let defaultQuery = "is:unresolved is:for_review"

    struct SentryConnectorError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        // SyncEngine surfaces poll failures via `String(describing:)` rather
        // than `localizedDescription`; conform to both so the message renders
        // either way. Same reasoning as GitHubConnector's error type.
        var description: String { errorDescription ?? "Sentry connector error" }
    }

    // MARK: Decoding

    struct Issue: Decodable, Sendable {
        struct Project: Decodable, Sendable {
            var slug: String?
            var name: String?
        }
        var id: String
        var title: String
        var culprit: String?
        var shortId: String?
        var permalink: String?
        var lastSeen: String?
        var firstSeen: String?
        var level: String?
        var count: String?
        var userCount: Int?
        var isUnhandled: Bool?
        var substatus: String?
        var project: Project?
    }

    // MARK: Fetch

    func fetch() async throws -> [RemoteItem] {
        guard !org.isEmpty else {
            throw SentryConnectorError(
                errorDescription:
                    "Sentry: no organization slug configured for source \(sourceID). It's the `sentry.io/organizations/<slug>/` part of your URL."
            )
        }
        guard let token = Keychain.get("\(sourceID).token"), !token.isEmpty else {
            throw SentryConnectorError(
                errorDescription:
                    "Sentry: no auth token configured for source \(sourceID).")
        }

        var collected: [Issue] = []
        var cursor: String?
        var complete = true

        for page in 1...Self.maxPages {
            let (issues, nextCursor) = try await fetchPage(
                token: token, cursor: cursor)
            collected.append(contentsOf: issues)
            guard let nextCursor else { break }
            cursor = nextCursor
            if page == Self.maxPages { complete = false }
        }

        snapshotComplete = complete
        return collected.map(Self.item(from:))
    }

    func snapshotWasComplete() async -> Bool { snapshotComplete }

    private func fetchPage(
        token: String, cursor: String?
    ) async throws -> (issues: [Issue], nextCursor: String?) {
        var request = URLRequest(url: Self.issuesURL(org: org, query: query, cursor: cursor))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SentryConnectorError(
                errorDescription: "Sentry: non-HTTP response from the issues endpoint.")
        }
        guard http.statusCode == 200 else {
            throw SentryConnectorError(
                errorDescription: Self.problem(
                    forHTTPStatus: http.statusCode,
                    body: String(data: data.prefix(500), encoding: .utf8),
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                    org: org))
        }

        let issues = try JSONDecoder().decode([Issue].self, from: data)
        return (issues, Self.nextCursor(inLinkHeader: http.value(forHTTPHeaderField: "Link")))
    }

    // MARK: Write-through

    func markDone(externalID: String, payload: Data?) async throws {
        // Belt and braces: SyncEngine only calls this when `.markDone` is
        // declared, but the capability is decided by a user toggle, so make
        // the guard explicit rather than trusting the wiring.
        guard resolveOnDone else { return }
        guard let token = Keychain.get("\(sourceID).token"), !token.isEmpty else {
            throw SentryConnectorError(
                errorDescription:
                    "Sentry: no auth token configured for source \(sourceID), so “\(externalID)” could not be resolved."
            )
        }

        var components = URLComponents(
            string: "https://sentry.io/api/0/organizations/\(org)/issues/")!
        components.queryItems = [URLQueryItem(name: "id", value: externalID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"status":"resolved"}"#.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SentryConnectorError(
                errorDescription: "Sentry: non-HTTP response resolving issue \(externalID).")
        }
        guard http.statusCode == 200 || http.statusCode == 202 else {
            throw SentryConnectorError(
                errorDescription: "Resolving Sentry issue \(externalID) failed. "
                    + Self.problem(
                        forHTTPStatus: http.statusCode,
                        body: String(data: data.prefix(500), encoding: .utf8),
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                        org: org))
        }
    }

    // MARK: Pure helpers (rule 5 — everything worth testing lives here)

    static func issuesURL(org: String, query: String, cursor: String?) -> URL {
        var components = URLComponents(
            string: "https://sentry.io/api/0/organizations/\(org)/issues/")!
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sort", value: "inbox"),
            URLQueryItem(name: "limit", value: String(perPage)),
            // `base` and `stats` are the expensive halves of the payload and
            // nothing here renders a sparkline.
            URLQueryItem(name: "collapse", value: "stats"),
        ]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = items
        return components.url!
    }

    /// Sentry's timestamps carry fractional seconds (`…:56.789Z`), which is
    /// exactly the shape a single `ISO8601DateFormatter` misses — see
    /// `ISO8601Timestamp` for why that needs two of them.
    ///
    /// Returning nil rather than `.now` is deliberate: `occurredAt` feeds
    /// `Store.resurrectIfNeeded`, and a `.now` fallback is always newer than
    /// `doneAt`, which makes the item impossible to dismiss. The caller
    /// decides what an unparseable date means; it must never silently become
    /// "just now".
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return ISO8601Timestamp.date(from: raw)
    }

    /// Sentry pages with an opaque cursor in an RFC 5988 `Link` header:
    /// `<https://…>; rel="next"; results="true"; cursor="0:100:0"`.
    /// `results="false"` means the next page is empty — following it would
    /// cost a round trip to learn nothing.
    static func nextCursor(inLinkHeader header: String?) -> String? {
        guard let header else { return nil }
        for link in header.split(separator: ",") {
            let parts = link.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.contains(where: { $0 == #"rel="next""# }) else { continue }
            guard parts.contains(where: { $0 == #"results="true""# }) else { return nil }
            guard
                let cursorPart = parts.first(where: { $0.hasPrefix("cursor=") })
            else { return nil }
            let value = cursorPart.dropFirst("cursor=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func item(from issue: Issue) -> RemoteItem {
        RemoteItem(
            externalID: issue.id,
            kind: issue.level ?? "error",
            title: issue.title,
            snippet: snippet(for: issue),
            url: issue.permalink,
            actorName: issue.project?.slug ?? issue.project?.name,
            // An issue with no parseable `lastSeen` is dated to the epoch
            // rather than to now. Both are wrong, but only one of them makes
            // the row immortal — `.now` beats every `doneAt` forever, while
            // `.distantPast` merely sorts the row to the bottom until Sentry
            // sends a timestamp we understand.
            occurredAt: parseTimestamp(issue.lastSeen) ?? .distantPast,
            highSignal: highSignal(level: issue.level, isUnhandled: issue.isUnhandled),
            // Stat chips for the D expansion, built from fields the list
            // response already carries — the lazy half (stack frames) is
            // fetched in `context()` only when the user asks.
            payload: contextData(for: issue),
            groupKey: issue.project?.slug ?? issue.project?.name,
            groupLabel: issue.project?.slug ?? issue.project?.name)
    }

    // MARK: Context (D expansion)

    /// Stat chips decode from the payload (written at poll time, free); the
    /// top stack frames cost one extra request to the issue's latest event,
    /// spent only when the user expands the row. A frames failure degrades
    /// to a named note rather than losing the chips (rule 5).
    func context(externalID: String, payload: Data?) async throws -> ItemContext? {
        var context = payload.flatMap {
            try? JSONDecoder().decode(ItemContext.self, from: $0)
        } ?? ItemContext()

        guard let token = Keychain.get("\(sourceID).token"), !token.isEmpty,
            !org.isEmpty
        else { return context.isEmpty ? nil : context }

        do {
            let event = try await fetchLatestEvent(issueID: externalID, token: token)
            let frames = Self.topFrames(from: event)
            if !frames.isEmpty {
                context.frames = frames
                context.framesLabel = "Latest event · top frames"
            }
        } catch {
            context.note = "Couldn't fetch the latest event: \(String(describing: error))"
        }
        return context.isEmpty ? nil : context
    }

    /// One event, `entries` and all. `collapse=stats` has no equivalent here;
    /// the payload is big but it's one request on an explicit keypress.
    private func fetchLatestEvent(issueID: String, token: String) async throws -> LatestEvent {
        let url = URL(
            string: "https://sentry.io/api/0/organizations/\(org)/issues/\(issueID)/events/latest/")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SentryConnectorError(errorDescription: "non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw SentryConnectorError(
                errorDescription: Self.problem(
                    forHTTPStatus: http.statusCode,
                    body: String(data: data.prefix(200), encoding: .utf8),
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                    org: org))
        }
        return try JSONDecoder().decode(LatestEvent.self, from: data)
    }

    /// The slice of an event detail that carries the exception stack.
    struct LatestEvent: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            var type: String
            var data: EntryData?
        }
        struct EntryData: Decodable, Sendable {
            var values: [ExceptionValue]?
        }
        struct ExceptionValue: Decodable, Sendable {
            var stacktrace: Stacktrace?
        }
        struct Stacktrace: Decodable, Sendable {
            var frames: [Frame]?
        }
        struct Frame: Decodable, Sendable {
            var function: String?
            var filename: String?
            var lineNo: Int?
            var inApp: Bool?
        }
        var entries: [Entry]?
    }

    /// Crash site first. Sentry orders frames oldest-call-first (the crash is
    /// the *last* frame), which is backwards for a four-line excerpt — the
    /// line that broke has to be the one you can't miss. Prefers in-app
    /// frames when the event marks any, since `Thread.run` twelve levels up
    /// says nothing.
    static func topFrames(from event: LatestEvent, limit: Int = 4) -> [String] {
        let all = (event.entries ?? [])
            .first { $0.type == "exception" }?
            .data?.values?
            .compactMap(\.stacktrace?.frames)
            .flatMap { $0 } ?? []
        guard !all.isEmpty else { return [] }
        let inApp = all.filter { $0.inApp == true }
        let chosen = inApp.isEmpty ? all : inApp
        return chosen.suffix(limit).reversed().map { frame in
            let function = frame.function ?? "<unknown>"
            var site = frame.filename ?? ""
            if let line = frame.lineNo { site += ":\(line)" }
            return site.isEmpty ? function : "\(function)  \(site)"
        }
    }

    /// Stat chips from fields the issues list already returned.
    static func contextData(for issue: Issue) -> Data? {
        var chips: [ItemContext.Chip] = []
        if let count = issue.count, count != "1", !count.isEmpty {
            chips.append(.init(
                systemImage: "bolt.fill", text: "\(count) events", tint: .orange))
        }
        if let users = issue.userCount, users > 0 {
            chips.append(.init(
                systemImage: "person.2",
                text: users == 1 ? "1 user" : "\(users) users"))
        }
        if let age = age(from: parseTimestamp(issue.firstSeen)) {
            chips.append(.init(systemImage: "clock", text: age))
        }
        if issue.isUnhandled == true {
            chips.append(.init(systemImage: "flag", text: "unhandled", tint: .red))
        }
        guard !chips.isEmpty else { return nil }
        return try? JSONEncoder().encode(ItemContext(chips: chips))
    }

    /// "3d old" / "5h old" / "just in" — how long this issue has existed.
    static func age(from firstSeen: Date?, now: Date = .now) -> String? {
        guard let firstSeen else { return nil }
        let seconds = now.timeIntervalSince(firstSeen)
        guard seconds >= 0 else { return nil }
        let days = Int(seconds / 86_400)
        if days >= 1 { return "\(days)d old" }
        let hours = Int(seconds / 3_600)
        if hours >= 1 { return "\(hours)h old" }
        return "just in"
    }

    /// The row's second line: where it broke, and how much. `culprit` is the
    /// code location, which is the one thing the title usually omits.
    static func snippet(for issue: Issue) -> String? {
        var parts: [String] = []
        if let culprit = issue.culprit, !culprit.isEmpty { parts.append(culprit) }
        if let count = issue.count, count != "1" { parts.append("\(count) events") }
        if let users = issue.userCount, users > 0 {
            parts.append(users == 1 ? "1 user" : "\(users) users")
        }
        if let shortID = issue.shortId, !shortID.isEmpty { parts.append(shortID) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `fatal`/`error` and anything unhandled earn the high-signal badge;
    /// `warning`/`info` do not, or the badge stops meaning anything.
    static func highSignal(level: String?, isUnhandled: Bool?) -> Bool {
        if isUnhandled == true { return true }
        guard let level else { return false }
        return level == "fatal" || level == "error"
    }

    /// Rule 4: say what to do about it, not just what went wrong.
    static func problem(
        forHTTPStatus status: Int, body: String?, retryAfter: String?, org: String
    ) -> String {
        let snippet = body.flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""
        switch status {
        case 401:
            return
                "Sentry rejected the token (401). Create a new one under Settings → Account → User Auth Tokens and make sure it has the `event:read` scope.\(snippet)"
        case 403:
            return
                "Sentry refused the request (403). The token is valid but lacks a scope — `event:read` to see issues, `event:write` to resolve them.\(snippet)"
        case 404:
            return
                "Sentry has no organization called “\(org)” (404). Use the slug from your URL: `sentry.io/organizations/<slug>/`.\(snippet)"
        case 429:
            let wait =
                retryAfter.map { " Sentry asked us to wait \($0)s." } ?? ""
            return
                "Sentry rate-limited the request (429).\(wait) Polling backs off on its own; if this keeps happening, narrow the query.\(snippet)"
        default:
            return "Sentry returned an unexpected status \(status).\(snippet)"
        }
    }
}
