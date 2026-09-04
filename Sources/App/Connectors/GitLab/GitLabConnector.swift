import Foundation

/// Polls GitLab's To-Do list, which **is** this app's queue.
///
/// `GET /todos` returns the authenticated user's pending to-dos — assigned,
/// mentioned, review approval wanted, pipeline broken — and
/// `POST /todos/:id/mark_as_done` clears one. That makes GitLab a 1:1 inbox
/// mirror of the same class as Linear, rather than the assigned-work
/// approximation Jira and Asana can manage (`docs/source-candidates.md`).
///
/// **Written against GitLab's documented payloads, never against a live
/// account** (2026-09-04, Brandon: *"i won't be able to test any of those 3
/// … because i don't have accounts with any of them"*). Every mapping helper
/// below is `nonisolated static` and tested against the response GitLab's own
/// docs publish, and every failure path names what to do — that discipline is
/// standing in for the live check the other connectors got, so keep it.
///
/// The one thing that *was* verified live: an unauthenticated and a
/// bad-token request to `gitlab.com/api/v4/todos` both answer **401 with
/// `{"message":"401 Unauthorized"}`**. GitLab cannot tell you which of
/// missing, wrong or expired it was, and a GitLab.com token expires (a year
/// by default, and the expiry date is mandatory), so `explain` has to name
/// all three at once. No other source in the app has a credential that dies
/// on a timer.
actor GitLabConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "gitlab"
    nonisolated let capabilities: ConnectorCapabilities = [
        .markDone, .remoteTruth,
    ]
    nonisolated let pollInterval: TimeInterval = 60

    /// `https://gitlab.com`, or a self-managed instance.
    private let baseURL: URL?
    /// A host that parsed but was refused, surfaced as a named error instead
    /// of a generic failure — same treatment `JSONPollerConnector` gives it.
    private let rejectedScheme: String?
    private var snapshotComplete = true

    /// GitLab's page maximum is 100. 10 × 100 = 1,000 pending to-dos, past
    /// which the snapshot reports itself incomplete rather than letting
    /// `.remoteTruth` archive a tail it never saw — the GitHub bug that cost
    /// an unkillable resurrect loop over ~946 items.
    static let perPage = 100
    static let maxPages = 10

    init(sourceID: String = "gitlab", host: String = "") {
        self.sourceID = sourceID
        let decision = Self.accept(host: host)
        self.baseURL = decision.url
        self.rejectedScheme = decision.rejectedScheme
    }

    // MARK: Host

    static let defaultHost = "https://gitlab.com"

    /// Resolves the instance URL. Blank means gitlab.com; anything that is
    /// not http(s) is refused by name, because a `file://` "instance" would
    /// otherwise be read off disk on every poll (the `jsonPoller` finding).
    nonisolated static func accept(
        host: String
    ) -> (url: URL?, rejectedScheme: String?) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.isEmpty ? defaultHost : trimmed
        guard let parsed = URL(string: candidate) else { return (nil, nil) }
        // Scheme first, host second — the order matters. `file:///etc/passwd`
        // parses with an *empty* host, so a host check placed ahead of this
        // swallowed the scheme and reported a generic "can't read that URL",
        // losing the one detail worth saying out loud. Caught by
        // `hostResolution` before it shipped.
        guard let scheme = parsed.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return (nil, parsed.scheme) }
        guard let host = parsed.host, !host.isEmpty else { return (nil, nil) }
        return (parsed, nil)
    }

    // MARK: Fetch

    func fetch() async throws -> [RemoteItem] {
        if let scheme = rejectedScheme {
            throw GitLabError(
                errorDescription:
                    "GitLab: the instance URL uses the “\(scheme)” scheme. Use one starting with https:// — or leave it blank for gitlab.com."
            )
        }
        guard let baseURL else {
            throw GitLabError(
                errorDescription:
                    "GitLab: that instance URL can't be read. Use something like https://gitlab.example.com, or leave it blank for gitlab.com."
            )
        }
        guard let token = Keychain.get("\(sourceID).token"), !token.isEmpty else {
            throw GitLabError(
                errorDescription:
                    "GitLab: no personal access token configured for this source."
            )
        }

        var collected: [RemoteItem] = []
        var complete = true
        var page = 1
        var fetched = 0

        while true {
            let (todos, nextPage) = try await fetchPage(
                page: page, token: token, baseURL: baseURL)
            collected.append(contentsOf: todos.map(Self.item(from:)))
            fetched += 1
            // `X-Next-Page` decides (see `nextPage(header:current:count:)`).
            // A short page is *not* a stop signal on its own: stopping on one
            // while GitLab says there is more would hand `.remoteTruth` a
            // truncated list reported as complete, and archive the tail.
            guard let nextPage else { break }
            if fetched >= Self.maxPages {
                complete = false
                break
            }
            page = nextPage
        }

        snapshotComplete = complete
        return collected
    }

    /// Which page to ask for next, or nil when this was the last.
    ///
    /// GitLab sends `X-Next-Page` on every response and leaves it **empty on
    /// the last page**, so when the header is present it is the answer. The
    /// page count is only a fallback for an instance (or a proxy) that drops
    /// the header: a full page then means "probably more", a short one "done".
    /// A header that names a page at or before the current one is treated as
    /// the end rather than trusted into a loop.
    nonisolated static func nextPage(
        header: String?, current: Int, count: Int
    ) -> Int? {
        if let header {
            let trimmed = header.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if let named = Int(trimmed) { return named > current ? named : nil }
        }
        return count >= perPage ? current + 1 : nil
    }

    func snapshotWasComplete() async -> Bool { snapshotComplete }

    private func fetchPage(
        page: Int, token: String, baseURL: URL
    ) async throws -> (todos: [Todo], nextPage: Int?) {
        var components = URLComponents(
            url: baseURL.appending(path: "/api/v4/todos"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "state", value: "pending"),
            URLQueryItem(name: "per_page", value: String(Self.perPage)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components?.url else {
            throw GitLabError(
                errorDescription:
                    "GitLab: couldn't build a request URL from “\(baseURL.absoluteString)”."
            )
        }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitLabError(
                errorDescription: "GitLab: non-HTTP response from /todos.")
        }
        guard http.statusCode == 200 else {
            throw GitLabError(
                errorDescription: Self.explain(
                    status: http.statusCode, body: data, writing: false))
        }
        let todos = try JSONDecoder().decode([Todo].self, from: data)
        let next = Self.nextPage(
            header: http.value(forHTTPHeaderField: "X-Next-Page"),
            current: page, count: todos.count)
        return (todos, next)
    }

    // MARK: Write-back

    /// `E` on a GitLab row marks the to-do done in GitLab, so it leaves the
    /// list and stops arriving.
    ///
    /// **A 404 is treated as success.** GitLab answers 404 for a to-do that
    /// is already done, and an error there would put a red dot on the source
    /// for doing exactly what was asked — the second time.
    func markDone(externalID: String, payload: Data?) async throws {
        guard let baseURL else {
            throw GitLabError(
                errorDescription:
                    "GitLab: no instance URL configured, so “\(externalID)” can't be marked done in GitLab. It was cleared from the queue only."
            )
        }
        guard let token = Keychain.get("\(sourceID).token"), !token.isEmpty else {
            throw GitLabError(
                errorDescription:
                    "GitLab: no personal access token configured, so “\(externalID)” was cleared from the queue only."
            )
        }
        var request = URLRequest(
            url: baseURL.appending(path: "/api/v4/todos/\(externalID)/mark_as_done"))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitLabError(
                errorDescription:
                    "GitLab: non-HTTP response marking to-do \(externalID) done.")
        }
        // 404 = already done. 304 is GitLab's answer when nothing changed.
        guard !(200...204).contains(http.statusCode), http.statusCode != 404,
            http.statusCode != 304
        else { return }
        throw GitLabError(
            errorDescription: Self.explain(
                status: http.statusCode, body: data, writing: true))
    }

    // MARK: Decoding

    /// Only the fields the queue uses, all optional but `id`, `action_name`
    /// and `created_at`.
    ///
    /// **`target.id` is deliberately absent.** A to-do's target can be a
    /// `Commit`, whose id is a SHA *string* while an issue's is a number —
    /// decoding it as either type would throw on the other and take the whole
    /// poll down with it. Nothing here needs it: `target_url` is the link and
    /// `iid` is the reference people quote.
    struct Todo: Decodable, Sendable {
        struct Project: Decodable, Sendable {
            var path_with_namespace: String?
            var name_with_namespace: String?
        }
        struct Author: Decodable, Sendable {
            var name: String?
            var username: String?
        }
        struct Target: Decodable, Sendable {
            var iid: Int?
            var title: String?
            /// `Namespace` and `Project` targets carry a name, not a title.
            var name: String?
        }
        var id: Int
        var action_name: String
        var target_type: String?
        var target: Target?
        var target_url: String?
        var body: String?
        var created_at: String
        var project: Project?
        var author: Author?
    }

    // MARK: Mapping (pure — rule 6)

    nonisolated static func item(from todo: Todo) -> RemoteItem {
        let grouping = grouping(project: todo.project)
        return RemoteItem(
            externalID: String(todo.id),
            kind: todo.action_name,
            title: title(for: todo),
            snippet: snippet(for: todo),
            url: todo.target_url?.nonEmpty,
            actorName: todo.author?.name?.nonEmpty
                ?? todo.author?.username?.nonEmpty,
            // An unparseable date goes to `.distantPast`, never `.now`:
            // `.now` beats every `doneAt`, so `Store.resurrectIfNeeded` would
            // revive the row on the next poll and it could never be
            // dismissed. Same choice `SentryConnector` and Mail make.
            occurredAt: ISO8601Timestamp.date(from: todo.created_at)
                ?? .distantPast,
            highSignal: isHighSignal(action: todo.action_name),
            groupKey: grouping?.key,
            groupLabel: grouping?.label)
    }

    /// "Assigned: !7 · Fix the upload retry".
    ///
    /// The reference leads rather than trails because a panel row truncates
    /// on the right, and `!7` is the token a person quotes in Slack.
    nonisolated static func title(for todo: Todo) -> String {
        let action = humanize(action: todo.action_name)
        let subject = subject(of: todo)
        guard let subject, !subject.isEmpty else {
            return action
        }
        guard let reference = reference(
            targetType: todo.target_type, iid: todo.target?.iid)
        else { return "\(action): \(subject)" }
        return "\(action): \(reference) · \(subject)"
    }

    /// What the to-do is about: the target's own title, else its name, else
    /// the to-do body (which for a mention is the comment text).
    nonisolated static func subject(of todo: Todo) -> String? {
        todo.target?.title?.nonEmpty ?? todo.target?.name?.nonEmpty
            ?? todo.body?.nonEmpty
    }

    /// The body when it says something the title does not — for a mention
    /// that is the comment, which is what `D` exists to reveal. Otherwise the
    /// project path, matching what GitHub's rows carry.
    nonisolated static func snippet(for todo: Todo) -> String? {
        let subject = subject(of: todo)
        if let body = todo.body?.nonEmpty, body != subject {
            return body
        }
        return todo.project?.path_with_namespace?.nonEmpty
    }

    /// `!7` for a merge request, `#34` for an issue, `&2` for an epic —
    /// GitLab's own sigils. Anything else has no short form worth printing.
    nonisolated static func reference(
        targetType: String?, iid: Int?
    ) -> String? {
        guard let targetType, let iid else { return nil }
        switch targetType {
        case "MergeRequest": return "!\(iid)"
        case "Issue": return "#\(iid)"
        case "Epic": return "&\(iid)"
        default: return nil
        }
    }

    /// Folds by project, exactly as GitHub folds by repository — the path is
    /// the stable key and the human name is the label.
    nonisolated static func grouping(
        project: Todo.Project?
    ) -> (key: String, label: String)? {
        guard let path = project?.path_with_namespace?.nonEmpty else {
            return nil
        }
        return (path, project?.name_with_namespace?.nonEmpty ?? path)
    }

    /// Actions where a *person* is waiting on you.
    ///
    /// `build_failed`, `unmergeable` and `merge_train_removed` are left out
    /// deliberately: they matter, but a machine raised them about your own
    /// branch, and marking them high-signal would put GitLab's CI noise in
    /// the same badge as a review request. Same line `GitHubConnector` draws
    /// by excluding `ci_activity`. `marked` is your own doing, so it is the
    /// quietest of all.
    nonisolated static let highSignalActions: Set<String> = [
        "assigned", "mentioned", "directly_addressed", "approval_required",
        "review_requested", "member_access_requested",
    ]

    nonisolated static func isHighSignal(action: String) -> Bool {
        highSignalActions.contains(action)
    }

    /// GitLab's `action_name` values, as sentences. An unknown action is
    /// de-snaked rather than dropped, so a new GitLab action reads acceptably
    /// instead of showing up as `merge_train_removed`.
    nonisolated static func humanize(action: String) -> String {
        switch action {
        case "assigned": return "Assigned"
        case "mentioned": return "Mentioned"
        case "directly_addressed": return "Addressed directly"
        case "approval_required": return "Approval needed"
        case "review_requested": return "Review requested"
        case "build_failed": return "Pipeline failed"
        case "unmergeable": return "Can't be merged"
        case "merge_train_removed": return "Dropped from the merge train"
        case "member_access_requested": return "Access requested"
        case "marked": return "You marked this"
        default:
            let spaced = action.replacingOccurrences(of: "_", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    // MARK: Failures (rule 5)

    /// Every failure the user can act on, with the action in it.
    ///
    /// The 401 wording is the load-bearing one and it comes from a live
    /// check: gitlab.com answers 401 with `{"message":"401 Unauthorized"}`
    /// for a missing token, a wrong token and (by construction) an expired
    /// one alike. Saying "check the token" alone would send someone hunting a
    /// typo in a token that is simply past its expiry date.
    nonisolated static func explain(
        status: Int, body: Data, writing: Bool
    ) -> String {
        let action = writing ? "marking a to-do done" : "reading your to-dos"
        switch status {
        case 401:
            return
                "GitLab rejected the token (401) while \(action). GitLab answers the same way whether a token is missing, wrong, or expired — and GitLab tokens expire, a year out by default — so check the expiry date on it as well as the value."
        case 403:
            return writing
                ? "GitLab refused to mark the to-do done (403). A token with only the `read_api` scope can read this queue but not clear it; create one with the `api` scope."
                : "GitLab refused the request (403) while \(action). Check that the token has the `read_api` or `api` scope."
        case 404:
            return
                "GitLab returned 404 while \(action). Check the instance URL — a self-managed GitLab behind a subpath needs that path included."
        case 429:
            return
                "GitLab is rate-limiting this source (429). It will try again on the next poll."
        case 500...599:
            return
                "GitLab returned a server error (\(status)) while \(action). Nothing is wrong with your setup; it will retry."
        default:
            let snippet = String(data: body.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return
                "GitLab returned an unexpected status (\(status)) while \(action). \(snippet)"
        }
    }

    struct GitLabError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        // SyncEngine renders a thrown error with `String(describing:)`, so
        // both spellings have to carry the sentence.
        var description: String { errorDescription ?? "GitLab connector error" }
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
