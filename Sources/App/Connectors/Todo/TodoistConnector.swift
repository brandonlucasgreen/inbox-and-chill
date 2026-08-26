import Foundation
import OSLog

/// Reads Todoist over its v1 REST API. The second provider behind the
/// `TodoTask` seam, and the one that proves the seam was worth having:
/// everything about how a task *behaves* in the queue — its identity, its
/// timestamp, whether it is high-signal, what `C` means, what the archive
/// keeps — is inherited unchanged from `TodoItemMapper`, `TodoScope` and
/// `TodoContext`. This file only knows how to turn a token into `[TodoTask]`.
///
/// **Why `.completesTask` and not `.markDone`,** identically to Reminders:
/// dismissing a to-do is not finishing it. `E` strikes the row locally and
/// Todoist never hears about it; `C` closes the task for real. Declaring
/// `.markDone` is what wires `E` to a write-through, so *not* declaring it is
/// the feature. See `ConnectorCapabilities.completesTask`.
///
/// ## Facts taken from Todoist's published API schema, 2026-08-26
///
/// 1. **`close` on a recurring task does not complete it — it advances it** to
///    the next occurrence, keeping the same id. Exactly what EventKit does,
///    and exactly why `TodoItemMapper.externalID` puts the occurrence day in
///    the queue's id: without that, a daily task would be marked done once and
///    never reappear.
/// 2. That same fact makes **undo lossy for recurring tasks**, and this
///    connector says so rather than pretending otherwise — see `uncomplete`.
/// 3. **`GET /tasks` has no due-date parameter at all**, so the due window has
///    to go through the filter language (`TodoistAPI.dueWindowQuery`), while
///    chosen projects go through `project_id`. Two requests, unioned by task
///    id — the same two-query shape `RemindersConnector` uses for the same
///    reason.
/// 4. **Task ids are opaque alphanumeric strings**, and there is no `url`
///    field, so the deep link is constructed.
///
/// **Verified against a real account on 2026-08-26** by Brandon: a personal
/// token, his own tasks arriving in the queue, a task due at a time today
/// showing that time, and `C` on a repeating task producing the next
/// occurrence as its own row. So the shapes above are no longer just a
/// document — the decoding path, the due parsing and the recurrence identity
/// have all met the real service.
///
/// Still unexercised, and worth knowing before trusting either: **undo after
/// `C` on a repeating task** (the lossy path `uncomplete` reports), **paging
/// past the first page**, and the **rejected-token path**. Those remain rule
/// 4 territory.
actor TodoistConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "todoist"
    /// No `.markDone` — that omission is the dismiss-vs-complete feature.
    /// No `.announcesReturn` either: `local` is still the only source that
    /// declares it, and widening it is a decision to take with Brandon.
    nonisolated let capabilities: ConnectorCapabilities = [
        .completesTask, .remoteTruth, .providesContext,
    ]
    /// Slower than Reminders' 60s because this one costs a round trip, and a
    /// to-do list is not a notification stream — nothing here arrives that
    /// two minutes of latency spoils. Dismissal is local and instant either
    /// way. It also keeps a many-project source comfortably clear of
    /// Todoist's request ceiling.
    nonisolated let pollInterval: TimeInterval = 120

    private let scope: TodoScope
    private var snapshotComplete = true

    private static let log = Logger(
        subsystem: "lol.bgreen.inboxandchill", category: "todoist")

    /// Past this many tasks the snapshot is reported incomplete rather than
    /// letting `.remoteTruth` archive the tail — the trap `GitHubConnector`
    /// documents, and a live one here: a Todoist account with a long backlog
    /// project can exceed this easily.
    static let maxTasks = 200
    /// Pages per endpoint. 5 × 200 = 1,000 tasks before the same guard trips.
    static let maxPages = 5
    /// A backstop on requests per poll, not a policy — the project picker
    /// makes it hard to reach, and going over marks the snapshot incomplete
    /// rather than dropping tasks silently.
    static let maxProjects = 50

    init(sourceID: String, scope: TodoScope) {
        self.sourceID = sourceID
        self.scope = scope
    }

    struct TodoistError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        // `SyncEngine` surfaces failures via `String(describing:)` rather than
        // `localizedDescription`; conform to both so the message renders either
        // way. Same reasoning as `SentryConnector`'s error type.
        var description: String { errorDescription ?? "Todoist connector error" }
    }

    // MARK: Fetch

    func fetch() async throws -> [RemoteItem] {
        guard !scope.isEmpty else {
            throw TodoistError(
                errorDescription:
                    "This Todoist source isn't asking for anything yet. Turn on “Due today or overdue”, or pick at least one project, in Settings › Sources."
            )
        }
        let token = try self.token()

        // Projects first: they name every row, and they are how a chosen
        // project's title becomes the id `GET /tasks` wants.
        let projects = try await Self.projects(token: token)
        let namesByID = Dictionary(
            projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        var wireByID: [String: TodoistAPI.TaskEntry] = [:]
        var complete = true

        if scope.includesDueWindow {
            let (tasks, exhausted) = try await paged(token: token) { cursor in
                TodoistAPI.filterURL(
                    query: TodoistAPI.dueWindowQuery, cursor: cursor)
            }
            for task in tasks { wireByID[task.id] = task }
            complete = complete && exhausted
        }

        if !scope.listNames.isEmpty {
            let wanted = Self.resolveProjects(named: scope.listNames, in: projects)
            if wanted.isEmpty {
                // Every name the user chose is gone. Named rather than
                // swallowed, because an empty source looks like a quiet day
                // (rule 5) — and only when nothing else filled the queue, so
                // a working due-window mode is not broken by a stale project.
                if !scope.includesDueWindow || wireByID.isEmpty {
                    throw TodoistError(
                        errorDescription: Self.missingProjectsMessage(
                            scope.listNames))
                }
            }
            let capped = wanted.prefix(Self.maxProjects)
            if capped.count < wanted.count {
                complete = false
                Self.log.info(
                    "Todoist source watches \(wanted.count) projects; only \(Self.maxProjects) read this poll, archiving suppressed"
                )
            }
            for project in capped {
                let (tasks, exhausted) = try await paged(token: token) { cursor in
                    TodoistAPI.projectTasksURL(
                        projectID: project.id, cursor: cursor)
                }
                for task in tasks { wireByID[task.id] = task }
                complete = complete && exhausted
            }
        }

        let now = Date.now
        let tasks =
            wireByID.values
            .filter(\.isActive)
            .map { TodoistAPI.task(from: $0, projectNames: namesByID) }
        let accepted = tasks.filter { scope.accepts($0, now: now) }
        let ordered = TodoItemMapper.rank(accepted)

        snapshotComplete = complete && ordered.count <= Self.maxTasks
        if ordered.count > Self.maxTasks {
            Self.log.info(
                "Todoist snapshot capped at \(Self.maxTasks) of \(ordered.count); archiving suppressed"
            )
        }
        return ordered.prefix(Self.maxTasks).map {
            TodoItemMapper.remoteItem(from: $0, now: now)
        }
    }

    func snapshotWasComplete() async -> Bool { snapshotComplete }

    /// Matches the user's chosen names against real projects, case-insensitively.
    ///
    /// Names rather than ids, per `TodoScope`: readable in the settings JSON
    /// and in a bug report, and a name that no longer exists is something the
    /// source can *say*.
    nonisolated static func resolveProjects(
        named names: [String], in projects: [TodoistAPI.Project]
    ) -> [TodoistAPI.Project] {
        projects.filter { project in
            project.isUsable
                && names.contains {
                    $0.caseInsensitiveCompare(project.name) == .orderedSame
                }
        }
    }

    nonisolated static func missingProjectsMessage(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }.joined(separator: " or ")
        return
            "No Todoist project called \(quoted). Projects are matched by name, so renaming one in Todoist breaks the link — pick it again in Settings › Sources."
    }

    // MARK: HTTP

    private func token() throws -> String {
        guard let token = Keychain.get("\(sourceID).token"), !token.isEmpty else {
            throw TodoistError(
                errorDescription:
                    "Todoist: no API token configured for source \(sourceID). Paste one from Todoist → Settings → Integrations → Developer."
            )
        }
        return token
    }

    /// Walks a cursor-paginated endpoint. Returns the rows plus whether the
    /// walk reached the end.
    ///
    /// The second half of that tuple is the whole point: `next_cursor` being
    /// `null` is the **only** end-of-list signal Todoist gives — a short page
    /// does not mean the end — and stopping early without saying so would let
    /// `.remoteTruth` archive everything past the cap.
    /// Walks a cursor-paginated task endpoint. Returns the rows plus whether
    /// the walk reached the end.
    ///
    /// The second half of that tuple is the whole point: `next_cursor` being
    /// `null` is the **only** end-of-list signal Todoist gives — a short page
    /// does not mean the end — and stopping early without saying so would let
    /// `.remoteTruth` archive everything past the cap.
    private func paged(
        token: String, url: (String?) -> URL?
    ) async throws -> ([TodoistAPI.TaskEntry], exhausted: Bool) {
        var collected: [TodoistAPI.TaskEntry] = []
        var cursor: String?
        for page in 1...Self.maxPages {
            let batch: TodoistAPI.Page<TodoistAPI.TaskEntry> = try await Self.get(
                url: url(cursor), token: token)
            collected.append(contentsOf: batch.results)
            guard let next = batch.nextCursor, !next.isEmpty else {
                return (collected, true)
            }
            cursor = next
            if page == Self.maxPages {
                Self.log.info(
                    "Todoist paging stopped at \(Self.maxPages) pages; archiving suppressed"
                )
            }
        }
        return (collected, false)
    }

    /// Every project on the account, for naming rows and resolving chosen
    /// projects to ids.
    ///
    /// `static` and token-taking so the source editor can call it to populate
    /// its picker — the same code path the connector uses, so a token that
    /// works in the editor works in the poll.
    static func projects(token: String) async throws -> [TodoistAPI.Project] {
        var collected: [TodoistAPI.Project] = []
        var cursor: String?
        for _ in 1...maxPages {
            let page: TodoistAPI.Page<TodoistAPI.Project> = try await get(
                url: TodoistAPI.projectsURL(cursor: cursor), token: token)
            collected.append(contentsOf: page.results.filter(\.isUsable))
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        return collected
    }

    /// One authenticated GET, decoded. Errors are *named* — a bare throw here
    /// reaches the user as an empty source, which for a to-do list is
    /// indistinguishable from a free afternoon.
    static func get<T: Decodable & Sendable>(url: URL?, token: String) async throws
        -> T
    {
        guard let url else {
            throw TodoistError(
                errorDescription: "Todoist: could not build a request URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TodoistError(
                errorDescription: "Todoist: non-HTTP response from \(url.path).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TodoistError(
                errorDescription: TodoistAPI.problem(
                    forHTTPStatus: http.statusCode,
                    body: String(data: data.prefix(300), encoding: .utf8),
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TodoistError(
                errorDescription:
                    "Todoist sent a response this version can't read (\(url.path)). That usually means the API changed: \(error.localizedDescription)"
            )
        }
    }

    /// One authenticated POST with no body, for close/reopen.
    private func post(url: URL?, token: String, describing what: String)
        async throws
    {
        guard let url else {
            throw TodoistError(
                errorDescription: "Todoist: could not build the \(what) URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TodoistError(
                errorDescription: "Todoist: non-HTTP response to \(what).")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TodoistError(
                errorDescription: TodoistAPI.problem(
                    forHTTPStatus: http.statusCode,
                    body: String(data: data.prefix(300), encoding: .utf8),
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
        }
    }

    // MARK: Write-through

    /// Closes the task in Todoist.
    ///
    /// Safe on a repeating task, and for the same reason it is safe in
    /// Reminders: Todoist documents `close` as scheduling a recurring task to
    /// its next occurrence rather than completing it. The next occurrence then
    /// arrives as a different queue row, because its external id carries a
    /// different day.
    func complete(externalID: String, payload: Data?) async throws {
        let token = try self.token()
        let id = TodoPayload.providerID(externalID: externalID, payload: payload)
        try await post(
            url: TodoistAPI.taskActionURL(taskID: id, action: "close"),
            token: token, describing: "close that task")
    }

    /// Reopens it again, for ⌘Z.
    ///
    /// **Undo is genuinely lossy for a recurring task, and this says so.**
    /// `close` advanced the task to its next occurrence rather than completing
    /// it, so there is nothing for `reopen` to restore — the old due date is
    /// gone from Todoist and no API call brings it back. Reporting that is the
    /// rule-5 call: the alternative is an undo that puts the row back, leaves
    /// Todoist rescheduled, and never mentions the difference.
    ///
    /// The local row is restored either way — `SyncEngine.undoDone` writes to
    /// the store before it calls this — so the message explains a partial
    /// success, not a failure.
    func uncomplete(externalID: String, payload: Data?) async throws {
        let token = try self.token()
        let id = TodoPayload.providerID(externalID: externalID, payload: payload)
        if TodoPayload.decode(payload)?.isRecurring == true {
            throw TodoistError(errorDescription: Self.recurringUndoNote)
        }
        try await post(
            url: TodoistAPI.taskActionURL(taskID: id, action: "reopen"),
            token: token, describing: "reopen that task")
    }

    nonisolated static let recurringUndoNote =
        "The row is back, but Todoist had already rolled this repeating task on to its next occurrence — completing a recurring task reschedules it rather than ticking it off, so there's nothing to reopen. Set the date you wanted in Todoist."

    // MARK: Context (D)

    func context(externalID: String, payload: Data?) async throws -> ItemContext? {
        guard let decoded = TodoPayload.decode(payload) else { return nil }
        return TodoContext.chips(from: decoded, now: .now)
    }
}
