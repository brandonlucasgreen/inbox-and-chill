import Foundation

/// Polls GitHub's notifications API. Unread threads become `RemoteItem`s;
/// `markDone` marks the thread read on GitHub so it drops out of future
/// snapshots. Uses `If-Modified-Since`/`Last-Modified` so quiet polls cost
/// GitHub nothing (304s don't count against the primary rate limit).
actor GitHubConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "github"
    nonisolated let capabilities: ConnectorCapabilities = [
        .markDone, .remoteTruth, .providesContext,
    ]
    // GitHub's docs ask polling clients to respect `X-Poll-Interval` (60s by
    // default, sometimes raised under load). We can't surface a dynamic
    // value here because `pollInterval` is `nonisolated` and can't read
    // actor state — so we fix it at GitHub's documented default and lean on
    // If-Modified-Since caching (free 304s) to stay well-behaved even if the
    // server would have tolerated a slower cadence.
    nonisolated let pollInterval: TimeInterval = 60

    private var lastModified: String?
    private var cachedSnapshot: [RemoteItem] = []
    /// False when the last fetch stopped at `maxPages` with a full final page,
    /// i.e. GitHub still had more unread notifications to give us.
    private var snapshotComplete = true

    /// GitHub caps `/notifications` at 50 per page — that is both the default
    /// *and* the documented maximum — so a busy inbox must be paged through.
    /// Failing to do so was a real bug: with `.remoteTruth`, every unread
    /// notification past the first 50 looked like one the user had handled
    /// remotely, got auto-archived, and then sprang back the moment the
    /// 50-item window slid far enough for it to reappear.
    private static let perPage = 50
    /// 20 × 50 = 1,000 unread notifications. Past that we report the snapshot
    /// as incomplete rather than pretend the tail doesn't exist.
    private static let maxPages = 20

    /// `participating=true` narrows GitHub's firehose to threads you're
    /// actually in — mentioned, assigned, review-requested, or already
    /// commented on. Without it, `/notifications` returns activity from every
    /// repo you watch, which on a busy monorepo org is thousands of items and
    /// makes a triage queue useless.
    private let participating: Bool

    init(sourceID: String = "github", participating: Bool = true) {
        self.participating = participating
        self.sourceID = sourceID
    }

    private struct Thread: Decodable {
        struct Subject: Decodable {
            var title: String
            var url: String?
            var latest_comment_url: String?
            var type: String
        }
        struct Repository: Decodable {
            var full_name: String
        }
        var id: String
        var reason: String
        var unread: Bool
        var updated_at: String
        var subject: Subject
        var repository: Repository
    }

    struct GitHubConnectorError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        // SyncEngine surfaces poll failures via `String(describing: error)`
        // rather than `localizedDescription`; conform to both so the
        // message renders cleanly either way.
        var description: String { errorDescription ?? "GitHub connector error" }
    }

    func fetch() async throws -> [RemoteItem] {
        guard let pat = Keychain.get("\(sourceID).pat") else {
            throw GitHubConnectorError(errorDescription: "GitHub: no personal access token configured for source \(sourceID).")
        }

        var collected: [RemoteItem] = []
        var complete = true

        for page in 1...Self.maxPages {
            var components = URLComponents(string: "https://api.github.com/notifications")!
            var query = [
                URLQueryItem(name: "per_page", value: String(Self.perPage)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            if participating {
                query.append(URLQueryItem(name: "participating", value: "true"))
            }
            components.queryItems = query
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            // Conditional requests are per-page-1 only: it's the cheap "has
            // anything changed at all?" probe. Later pages are unconditional,
            // since a 304 on page 3 would silently truncate the snapshot.
            if page == 1, let lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }

            let (pageItems, isLastPage) = try await fetchPage(
                request: request, isFirstPage: page == 1)
            guard let pageItems else {
                // 304 on page 1: nothing has changed, so the cached snapshot
                // is still accurate — including its completeness.
                return cachedSnapshot
            }
            collected.append(contentsOf: pageItems)
            if isLastPage { break }
            if page == Self.maxPages { complete = false }
        }

        snapshotComplete = complete
        cachedSnapshot = collected
        return collected
    }

    func snapshotWasComplete() async -> Bool { snapshotComplete }

    /// Fetches one page. Returns `(nil, true)` for a 304, and
    /// `isLastPage == true` once GitHub returns a short page.
    private func fetchPage(
        request: URLRequest, isFirstPage: Bool
    ) async throws -> (items: [RemoteItem]?, isLastPage: Bool) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubConnectorError(errorDescription: "GitHub: non-HTTP response from /notifications.")
        }

        if http.statusCode == 304 {
            return (nil, true)
        }

        guard http.statusCode == 200 else {
            let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable body>"
            switch http.statusCode {
            case 401:
                throw GitHubConnectorError(errorDescription: "GitHub: unauthorized (401) — check the PAT. \(bodySnippet)")
            case 403:
                throw GitHubConnectorError(errorDescription: "GitHub: forbidden (403) — token may lack the `notifications` scope, or rate limit was hit. \(bodySnippet)")
            case 422:
                throw GitHubConnectorError(errorDescription: "GitHub: unprocessable (422). \(bodySnippet)")
            default:
                throw GitHubConnectorError(errorDescription: "GitHub: unexpected status \(http.statusCode). \(bodySnippet)")
            }
        }

        // Only page 1 carries the validator we send back next time.
        if isFirstPage, let newLastModified = http.value(forHTTPHeaderField: "Last-Modified") {
            lastModified = newLastModified
        }

        let threads = try JSONDecoder().decode([Thread].self, from: data)
        // A short page means we've reached the end. Judge that on the raw
        // thread count, before the `unread` filter — a full page of already-read
        // threads still means more pages exist.
        let isLastPage = threads.count < Self.perPage
        return (threads.filter(\.unread).map(makeRemoteItem), isLastPage)
    }

    func markDone(externalID: String, payload: Data?) async throws {
        guard let pat = Keychain.get("\(sourceID).pat") else {
            throw GitHubConnectorError(errorDescription: "GitHub: no personal access token configured for source \(sourceID).")
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/notifications/threads/\(externalID)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubConnectorError(errorDescription: "GitHub: non-HTTP response marking thread \(externalID) done.")
        }
        guard http.statusCode == 205 || http.statusCode == 204 else {
            let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable body>"
            switch http.statusCode {
            case 401:
                throw GitHubConnectorError(errorDescription: "GitHub: unauthorized (401) marking thread done — check the PAT. \(bodySnippet)")
            case 403:
                throw GitHubConnectorError(errorDescription: "GitHub: forbidden (403) marking thread done. \(bodySnippet)")
            case 422:
                throw GitHubConnectorError(errorDescription: "GitHub: unprocessable (422) marking thread done. \(bodySnippet)")
            default:
                throw GitHubConnectorError(errorDescription: "GitHub: unexpected status \(http.statusCode) marking thread done. \(bodySnippet)")
            }
        }

        // Drop it from the cached snapshot so a subsequent 304 doesn't
        // resurrect an item we just told GitHub (and the local store) is done.
        cachedSnapshot.removeAll { $0.externalID == externalID }
    }

    // MARK: Mapping

    private func makeRemoteItem(from thread: Thread) -> RemoteItem {
        let title = "\(Self.humanize(reason: thread.reason)): \(thread.subject.title)"
        let occurredAt = ISO8601Timestamp.date(from: thread.updated_at) ?? .now
        let highSignal = Self.highSignalReasons.contains(thread.reason)
        return RemoteItem(
            externalID: thread.id,
            kind: thread.reason,
            title: title,
            snippet: thread.repository.full_name,
            url: Self.htmlURL(for: thread.subject),
            actorName: nil,
            occurredAt: occurredAt,
            highSignal: highSignal,
            // The API URLs `context()` needs — the notifications response
            // carries them but the store doesn't keep the raw thread.
            payload: try? JSONEncoder().encode(StoredSubject(
                subjectURL: thread.subject.url,
                commentURL: thread.subject.latest_comment_url,
                reason: thread.reason)))
    }

    // MARK: Context (D expansion)

    /// What `context()` needs later, written into the item's payload at poll
    /// time. Both URLs point at api.github.com and came from GitHub itself.
    struct StoredSubject: Codable, Sendable {
        var subjectURL: String?
        var commentURL: String?
        var reason: String?
    }

    /// Labels and state from the subject (issue/PR), plus the body of the
    /// comment that produced the notification. Two REST GETs with the same
    /// PAT, spent only on an explicit expand.
    ///
    /// The trap this must name: the setup asks for a token with only the
    /// `notifications` scope, and *reading content* in a private repo needs
    /// `repo` — GitHub answers 404 (not 403) for that, so a bare "not found"
    /// would send the user hunting a deleted issue that's right there.
    func context(externalID: String, payload: Data?) async throws -> ItemContext? {
        guard let payload,
            let stored = try? JSONDecoder().decode(StoredSubject.self, from: payload)
        else { return nil }
        guard let pat = Keychain.get("\(sourceID).pat") else {
            throw GitHubConnectorError(
                errorDescription: "GitHub: no personal access token configured.")
        }

        var context = ItemContext()
        var problem: String?

        if let subjectURL = stored.subjectURL,
            subjectURL.hasPrefix("https://api.github.com/") {
            do {
                let detail: SubjectDetail = try await get(subjectURL, pat: pat)
                context.chips = Self.contextChips(for: detail)
            } catch {
                problem = String(describing: error)
            }
        }
        if let commentURL = stored.commentURL,
            commentURL.hasPrefix("https://api.github.com/") {
            do {
                let comment: CommentDetail = try await get(commentURL, pat: pat)
                if let body = comment.body, !body.isEmpty {
                    context.messages = [.init(
                        author: comment.user?.login ?? "someone",
                        text: String(body.prefix(600)),
                        isFocus: true)]
                    context.messagesLabel =
                        stored.reason == "mention" || stored.reason == "team_mention"
                        ? "The comment that mentioned you" : "Latest comment"
                }
            } catch {
                problem = problem ?? String(describing: error)
            }
        }

        if let problem {
            // Nothing loaded at all → surface the failure as the result;
            // partial results carry the problem as a note instead (rule 5).
            guard !context.isEmpty else {
                throw GitHubConnectorError(errorDescription: problem)
            }
            context.note = problem
        }
        return context.isEmpty ? nil : context
    }

    private func get<T: Decodable>(_ urlString: String, pat: String) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw GitHubConnectorError(errorDescription: "GitHub: malformed API URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubConnectorError(errorDescription: "GitHub: non-HTTP response.")
        }
        guard http.statusCode == 200 else {
            throw GitHubConnectorError(
                errorDescription: Self.contextProblem(status: http.statusCode))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct SubjectDetail: Decodable, Sendable {
        struct Label: Decodable, Sendable {
            var name: String
            var color: String?
        }
        struct User: Decodable, Sendable {
            var login: String
        }
        var state: String?
        var merged: Bool?
        var draft: Bool?
        var labels: [Label]?
        var requested_reviewers: [User]?
    }

    struct CommentDetail: Decodable, Sendable {
        struct User: Decodable, Sendable {
            var login: String
        }
        var user: User?
        var body: String?
    }

    /// State first, then labels, then reviewers — same order every time so
    /// the chips read as a sentence.
    static func contextChips(for detail: SubjectDetail) -> [ItemContext.Chip] {
        var chips: [ItemContext.Chip] = []
        if detail.merged == true {
            chips.append(.init(systemImage: "arrow.triangle.merge", text: "Merged"))
        } else if detail.draft == true {
            chips.append(.init(systemImage: "circle.dashed", text: "Draft"))
        } else if let state = detail.state {
            chips.append(.init(
                systemImage: "smallcircle.filled.circle",
                text: state.capitalized,
                tint: state == "open" ? .green : .red))
        }
        for label in detail.labels ?? [] where !label.name.isEmpty {
            chips.append(.init(dotHex: label.color, text: label.name))
        }
        if let reviewers = detail.requested_reviewers, !reviewers.isEmpty {
            chips.append(.init(
                systemImage: "person",
                text: reviewers.count == 1 ? "1 reviewer" : "\(reviewers.count) reviewers"))
        }
        return chips
    }

    /// Rule 5: 404 on a notification subject almost always means scope, not
    /// absence — the notification itself proves the thing exists.
    static func contextProblem(status: Int) -> String {
        switch status {
        case 404:
            return "GitHub answered 404 for this thread's details. For a "
                + "private repo that usually means the token lacks the repo "
                + "scope — add it under GitHub → Settings → Developer "
                + "settings → Tokens (classic), then Authorize for SSO orgs."
        case 403:
            return "GitHub refused the request (403) — rate limited, or the "
                + "token isn't authorized for this organization's SSO."
        case 401:
            return "GitHub rejected the token (401) — it may have expired."
        default:
            return "GitHub answered \(status) fetching the thread's details."
        }
    }

    private static let highSignalReasons: Set<String> = [
        "mention", "review_requested", "assign", "team_mention",
    ]

    private static func humanize(reason: String) -> String {
        switch reason {
        case "mention": return "Mentioned"
        case "review_requested": return "Review requested"
        case "assign": return "Assigned"
        case "author": return "New activity"
        case "team_mention": return "Team mentioned"
        case "subscribed": return "Subscribed thread"
        case "ci_activity": return "CI activity"
        case "comment": return "New comment"
        case "manual": return "Manually subscribed"
        case "security_alert": return "Security alert"
        case "state_change": return "State changed"
        case "invitation": return "Invitation"
        default: return reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// `subject.url` is an API URL, e.g.
    /// `https://api.github.com/repos/owner/repo/pulls/123`. Do the simple,
    /// well-known transforms to the browsable html_url shape; anything that
    /// doesn't match a known pattern falls back to the notifications inbox
    /// rather than guessing at a broken link.
    private static func htmlURL(for subject: Thread.Subject) -> String {
        let fallback = "https://github.com/notifications"
        guard let apiURL = subject.url, apiURL.hasPrefix("https://api.github.com/repos/") else {
            return fallback
        }

        if subject.type == "Release" {
            // .../repos/owner/repo/releases/12345 -> .../owner/repo/releases/tag/<tag>
            // We don't have the tag name from this payload, so releases fall
            // back to the notifications page rather than a guessed URL.
            return fallback
        }

        var htmlURL = apiURL.replacingOccurrences(of: "api.github.com/repos", with: "github.com")
        htmlURL = htmlURL.replacingOccurrences(of: "/pulls/", with: "/pull/")
        return htmlURL
    }
}
