import Foundation

/// Polls GitHub's notifications API. Unread threads become `RemoteItem`s;
/// `markDone` marks the thread read on GitHub so it drops out of future
/// snapshots. Uses `If-Modified-Since`/`Last-Modified` so quiet polls cost
/// GitHub nothing (304s don't count against the primary rate limit).
actor GitHubConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "github"
    nonisolated let capabilities: ConnectorCapabilities = [.markDone, .remoteTruth]
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
        let occurredAt = Self.iso8601.date(from: thread.updated_at) ?? .now
        let highSignal = Self.highSignalReasons.contains(thread.reason)
        return RemoteItem(
            externalID: thread.id,
            kind: thread.reason,
            title: title,
            snippet: thread.repository.full_name,
            url: Self.htmlURL(for: thread.subject),
            actorName: nil,
            occurredAt: occurredAt,
            highSignal: highSignal)
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

    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()
}
