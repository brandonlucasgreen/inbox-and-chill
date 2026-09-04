import Foundation
import OSLog

/// Reads Asana over its REST API. The third provider behind the `TodoTask`
/// seam, and the second to prove the seam holds: like Todoist it adds two
/// files and changes none of `TodoTask`, `TodoItemMapper`, `TodoScope` or
/// `TodoContext`. This file only knows how to turn a personal access token
/// into `[TodoTask]`; everything about how a task *behaves* in the queue is
/// inherited.
///
/// **Why `.completesTask` and not `.markDone`,** identically to Reminders and
/// Todoist: dismissing a to-do is not finishing it. `E` strikes the row
/// locally and Asana never hears about it; `C` completes the task for real.
///
/// **Why a to-do source at all:** Asana's Inbox is not in its API — there is
/// no notifications endpoint, verified against its OpenAPI document on
/// 2026-09-04 (`docs/source-candidates.md`). "Tasks assigned to me" is the
/// honest thing the API can answer, and it is exactly what the seam models.
///
/// ## What is different from Todoist, in one place
///
/// - **Workspaces.** `GET /tasks?assignee=me` needs a `workspace`, so the
///   due-window mode is one request per workspace the token can see. Most
///   accounts have one or two; the cap is a backstop, not a policy.
/// - **A chosen project is everyone's tasks in it,** because the spec allows
///   `project` *or* `assignee`+`workspace`, never both. A shared team project
///   is therefore a different thing to tick than a personal Todoist project,
///   and the field help says so.
/// - **Undo is not lossy.** Asana has no recurrence in its API — a repeating
///   task is a *new* task each time — so `PUT completed=false` reopens the
///   very task `C` completed. The one thing it cannot do is remove the next
///   occurrence Asana spawned, and `uncomplete` says that when it happens.
///
/// **Never fed to a real account when written** (2026-09-04). What was
/// verified live without one: a missing and a wrong token both answer 401
/// with `{"errors":[{"message":"Not Authorized"}]}`. Everything else comes
/// from the spec, and the tests in `Tests/AsanaTests.swift` pin it. The
/// project picker in the source editor is the first thing that meets a real
/// token, on purpose: it is the cheapest call that proves the token works.
actor AsanaConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "asana"
    /// No `.markDone` — that omission is the dismiss-vs-complete feature.
    /// No `.announcesReturn`: `local` alone declares it (Brandon, 2026-08-20).
    nonisolated let capabilities: ConnectorCapabilities = [
        .completesTask, .remoteTruth, .providesContext,
    ]
    /// Same cadence as Todoist, for the same reason: a to-do list is not a
    /// notification stream, and dismissal is local and instant either way.
    nonisolated let pollInterval: TimeInterval = 120

    private let scope: TodoScope
    private var snapshotComplete = true

    private static let log = Logger(
        subsystem: "lol.bgreen.inboxandchill", category: "asana")

    /// Past this many tasks the snapshot is reported incomplete rather than
    /// letting `.remoteTruth` archive the tail — the `GitHubConnector` trap.
    static let maxTasks = 200
    /// Pages per query. Asana's page cap is 100, so 10 × 100 = 1,000 tasks
    /// before the same guard trips — the ceiling Todoist and GitLab share.
    static let maxPages = 10
    /// Workspaces read per poll. Beyond it the snapshot is incomplete, not
    /// truncated in silence.
    static let maxWorkspaces = 5
    /// Chosen projects read per poll; same backstop as Todoist's.
    static let maxProjects = 50

    init(sourceID: String, scope: TodoScope) {
        self.sourceID = sourceID
        self.scope = scope
    }

    struct AsanaError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        // `SyncEngine` renders a thrown error with `String(describing:)`, so
        // both spellings carry the sentence.
        var description: String { errorDescription ?? "Asana connector error" }
    }

    // MARK: Fetch

    func fetch() async throws -> [RemoteItem] {
        guard !scope.isEmpty else {
            throw AsanaError(
                errorDescription:
                    "This Asana source isn't asking for anything yet. Turn on “Due today or overdue”, or pick at least one project, in Settings › Sources."
            )
        }
        let token = try self.token()

        let allWorkspaces = try await Self.workspaces(token: token)
        guard !allWorkspaces.isEmpty else {
            throw AsanaError(
                errorDescription:
                    "This Asana token can't see any workspace. It was probably created in an account that has none yet — check which account you were signed into when you made it."
            )
        }
        var complete = true
        let workspaces = Array(allWorkspaces.prefix(Self.maxWorkspaces))
        if workspaces.count < allWorkspaces.count {
            complete = false
            Self.log.info(
                "Asana token sees \(allWorkspaces.count) workspaces; only \(Self.maxWorkspaces) read this poll, archiving suppressed"
            )
        }

        var wireByGID: [String: AsanaAPI.TaskEntry] = [:]

        if scope.includesDueWindow {
            for workspace in workspaces {
                let (tasks, exhausted) = try await paged(token: token) { offset in
                    AsanaAPI.myTasksURL(workspace: workspace.gid, offset: offset)
                }
                for task in tasks { wireByGID[task.gid] = task }
                complete = complete && exhausted
            }
        }

        if !scope.listNames.isEmpty {
            let projects = try await Self.projects(token: token, in: workspaces)
            let wanted = Self.resolveProjects(named: scope.listNames, in: projects)
            if wanted.isEmpty {
                // Every name the user chose is gone. Named rather than
                // swallowed (rule 5) — and only when nothing else filled the
                // queue, so a working due-window mode is not broken by one
                // stale project.
                if !scope.includesDueWindow || wireByGID.isEmpty {
                    throw AsanaError(
                        errorDescription: Self.missingProjectsMessage(scope.listNames))
                }
            }
            let capped = wanted.prefix(Self.maxProjects)
            if capped.count < wanted.count {
                complete = false
                Self.log.info(
                    "Asana source watches \(wanted.count) projects; only \(Self.maxProjects) read this poll, archiving suppressed"
                )
            }
            for project in capped {
                let (tasks, exhausted) = try await paged(token: token) { offset in
                    AsanaAPI.projectTasksURL(project: project.gid, offset: offset)
                }
                for task in tasks { wireByGID[task.gid] = task }
                complete = complete && exhausted
            }
        }

        let now = Date.now
        let tasks =
            wireByGID.values
            .filter(\.isActive)
            .map { AsanaAPI.task(from: $0, preferring: scope.listNames) }
        let accepted = tasks.filter { scope.accepts($0, now: now) }
        let ordered = TodoItemMapper.rank(accepted)

        snapshotComplete = complete && ordered.count <= Self.maxTasks
        if ordered.count > Self.maxTasks {
            Self.log.info(
                "Asana snapshot capped at \(Self.maxTasks) of \(ordered.count); archiving suppressed"
            )
        }
        return ordered.prefix(Self.maxTasks).map {
            TodoItemMapper.remoteItem(from: $0, now: now)
        }
    }

    func snapshotWasComplete() async -> Bool { snapshotComplete }

    /// Matches the user's chosen names against real projects,
    /// case-insensitively. Names rather than gids, per `TodoScope`: readable
    /// in the settings JSON, and a name that no longer exists is something
    /// the source can *say*.
    nonisolated static func resolveProjects(
        named names: [String], in projects: [AsanaAPI.Project]
    ) -> [AsanaAPI.Project] {
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
            "No Asana project called \(quoted). Projects are matched by name, so renaming one in Asana breaks the link — pick it again in Settings › Sources."
    }

    // MARK: HTTP

    private func token() throws -> String {
        guard let token = Keychain.get("\(sourceID).token"), !token.isEmpty else {
            throw AsanaError(
                errorDescription:
                    "Asana: no personal access token configured for source \(sourceID). Create one in Asana's developer console and paste it in Settings › Sources."
            )
        }
        return token
    }

    /// Walks an offset-paginated list. Returns the rows plus whether the walk
    /// reached the end — and that second half is the point: `next_page` being
    /// `null` is the **only** end-of-list signal Asana gives, and stopping
    /// early without saying so would let `.remoteTruth` archive everything
    /// past the cap.
    private func paged(
        token: String, url: (String?) -> URL?
    ) async throws -> ([AsanaAPI.TaskEntry], exhausted: Bool) {
        var collected: [AsanaAPI.TaskEntry] = []
        var offset: String?
        for page in 1...Self.maxPages {
            let batch: AsanaAPI.Envelope<AsanaAPI.TaskEntry> = try await Self.get(
                url: url(offset), token: token)
            collected.append(contentsOf: batch.data)
            guard let next = batch.nextPage?.offset, !next.isEmpty else {
                return (collected, true)
            }
            offset = next
            if page == Self.maxPages {
                Self.log.info(
                    "Asana paging stopped at \(Self.maxPages) pages; archiving suppressed")
            }
        }
        return (collected, false)
    }

    /// Every workspace the token can see. One page is plenty — a person is
    /// in a handful — but the loop is honest about `next_page` anyway.
    static func workspaces(token: String) async throws -> [AsanaAPI.Workspace] {
        var collected: [AsanaAPI.Workspace] = []
        var offset: String?
        for _ in 1...maxPages {
            let page: AsanaAPI.Envelope<AsanaAPI.Workspace> = try await get(
                url: AsanaAPI.workspacesURL(offset: offset), token: token)
            collected.append(contentsOf: page.data)
            guard let next = page.nextPage?.offset, !next.isEmpty else { break }
            offset = next
        }
        return collected
    }

    /// Every live project across the given workspaces, for resolving chosen
    /// names to gids.
    static func projects(
        token: String, in workspaces: [AsanaAPI.Workspace]
    ) async throws -> [AsanaAPI.Project] {
        var collected: [AsanaAPI.Project] = []
        for workspace in workspaces {
            var offset: String?
            for _ in 1...maxPages {
                let page: AsanaAPI.Envelope<AsanaAPI.Project> = try await get(
                    url: AsanaAPI.projectsURL(workspace: workspace.gid, offset: offset),
                    token: token)
                collected.append(contentsOf: page.data.filter(\.isUsable))
                guard let next = page.nextPage?.offset, !next.isEmpty else { break }
                offset = next
            }
        }
        return collected
    }

    /// The names the source editor's picker offers — the same two calls the
    /// connector makes, so a token that works in the editor works in the
    /// poll. De-duplicated case-insensitively because two workspaces can
    /// each have a "Marketing", and `TodoScope` matches by name.
    static func projectNames(token: String) async throws -> [String] {
        let workspaces = try await workspaces(token: token)
        let projects = try await projects(token: token, in: workspaces)
        var seen = Set<String>()
        return projects.map(\.name).filter { seen.insert($0.lowercased()).inserted }
    }

    /// One authenticated GET, decoded. Errors are *named* — a bare throw here
    /// reaches the user as an empty source, which for a to-do list is
    /// indistinguishable from a free afternoon.
    static func get<T: Decodable & Sendable>(url: URL?, token: String) async throws -> T {
        guard let url else {
            throw AsanaError(errorDescription: "Asana: could not build a request URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await send(request, describing: url.path)
        guard (200..<300).contains(http.statusCode) else {
            throw AsanaError(
                errorDescription: AsanaAPI.problem(
                    forHTTPStatus: http.statusCode, body: data,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AsanaError(
                errorDescription:
                    "Asana sent a response this version can't read (\(url.path)). That usually means the API changed: \(error.localizedDescription)"
            )
        }
    }

    /// `PUT /tasks/{gid}` with a JSON body.
    private func put(url: URL?, body: Data, token: String, describing what: String)
        async throws
    {
        guard let url else {
            throw AsanaError(errorDescription: "Asana: could not build the \(what) URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await Self.send(request, describing: what)
        guard (200..<300).contains(http.statusCode) else {
            throw AsanaError(
                errorDescription: AsanaAPI.problem(
                    forHTTPStatus: http.statusCode, body: data,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")))
        }
    }

    /// Runs the request and rewraps a transport failure from
    /// `localizedDescription`. The token rides in a header so the URL holds
    /// no secret, but `String(describing: URLError)` prints the whole
    /// `NSError` and this keeps the framework's text out of the status line
    /// regardless — the Trello lesson, applied before it can bite.
    private static func send(
        _ request: URLRequest, describing what: String
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AsanaError(
                errorDescription:
                    "Asana couldn't be reached (\(what)): \(error.localizedDescription) It will try again on the next poll."
            )
        }
        guard let http = response as? HTTPURLResponse else {
            throw AsanaError(errorDescription: "Asana: non-HTTP response (\(what)).")
        }
        return (data, http)
    }

    // MARK: Write-through

    /// Completes the task in Asana.
    ///
    /// Safe on a repeating task, and *differently* safe from Reminders and
    /// Todoist: Asana's API has no recurrence, so what Asana does on
    /// completion — spawn the next occurrence as a new task — is invisible
    /// here and arrives as a new row on the next poll. The completed task
    /// keeps its gid, which is what makes `uncomplete` real.
    func complete(externalID: String, payload: Data?) async throws {
        let token = try self.token()
        let gid = TodoPayload.providerID(externalID: externalID, payload: payload)
        try await put(
            url: AsanaAPI.taskURL(gid: gid),
            body: AsanaAPI.completionBody(completed: true),
            token: token, describing: "complete that task")
    }

    /// Reopens it, for ⌘Z. Not lossy: the same task gets `completed=false`.
    /// If Asana spawned a next occurrence when `C` ran, it stays — there is
    /// no way to know from here that it exists — and it arrives as its own
    /// row, which is at least visible.
    func uncomplete(externalID: String, payload: Data?) async throws {
        let token = try self.token()
        let gid = TodoPayload.providerID(externalID: externalID, payload: payload)
        try await put(
            url: AsanaAPI.taskURL(gid: gid),
            body: AsanaAPI.completionBody(completed: false),
            token: token, describing: "reopen that task")
    }

    // MARK: Context (D)

    func context(externalID: String, payload: Data?) async throws -> ItemContext? {
        guard let decoded = TodoPayload.decode(payload) else { return nil }
        return TodoContext.chips(from: decoded, now: .now)
    }
}
