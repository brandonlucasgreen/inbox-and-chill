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

    init(sourceID: String = "github") {
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

        var request = URLRequest(url: URL(string: "https://api.github.com/notifications")!)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubConnectorError(errorDescription: "GitHub: non-HTTP response from /notifications.")
        }

        if http.statusCode == 304 {
            return cachedSnapshot
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

        if let newLastModified = http.value(forHTTPHeaderField: "Last-Modified") {
            lastModified = newLastModified
        }

        let threads = try JSONDecoder().decode([Thread].self, from: data)
        let items = threads.filter(\.unread).map(makeRemoteItem)
        cachedSnapshot = items
        return items
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
