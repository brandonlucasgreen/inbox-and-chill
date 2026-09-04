import Foundation

/// Everything about Asana's REST API that needs no network call: the wire
/// types, the URLs, the date parsing and the error wording. Split from
/// `AsanaConnector` for CLAUDE.md rule 6, exactly as `TodoistAPI` is split
/// from `TodoistConnector`.
///
/// ## Why Asana is a to-do source and not a notification source
///
/// Asana's OpenAPI document (`Asana/openapi`, fetched 2026-09-04) has **no
/// notifications or inbox path at all** — Asana's Inbox is simply not in the
/// API. What it has is tasks, filterable by assignee and workspace, and a
/// `completed` flag you can write. So Asana is the third provider behind the
/// `TodoTask` seam: `E` dismisses locally, `C` completes in Asana, and every
/// behavioural decision is inherited from `TodoItemMapper`, `TodoScope` and
/// `TodoContext`. This file only knows how to turn a token into `[TodoTask]`.
///
/// ## Facts taken from the spec, and two verified live without an account
///
/// 1. **`GET /tasks` wants exactly one filter shape.** `assignee` requires
///    `workspace` and vice versa, and `project` cannot be combined with
///    either. So "my tasks" is one request per workspace, and a chosen
///    project is one request that returns *everyone's* open tasks in it —
///    the field help says so, because a shared team project is not the same
///    thing as a personal Todoist project.
/// 2. **`completed_since=now`** is the documented way to ask for incomplete
///    tasks only; there is no `completed=false` parameter on this endpoint.
/// 3. **`next_page` is `null` on the last page**, and carries an `offset`
///    token otherwise. A short page is not the end. Free
///    `snapshotWasComplete()`, same as Todoist's `next_cursor`.
/// 4. **`due_on` and `due_at` are two fields**, not one string with two
///    shapes: `due_at` is a UTC instant and is set only for a timed task,
///    `due_on` is a `YYYY-MM-DD` day and is set for both. So `due_at` present
///    means timed, else `due_on` means all-day. Cleaner than Todoist, and
///    `ISO8601Timestamp` handles the instant.
/// 5. **There is no priority field** — Asana does priority through custom
///    fields, which vary per workspace — so every task arrives `.none`, and
///    the high-signal badge fires only on overdue.
/// 6. **There is no recurrence field either.** Asana implements a repeating
///    task by creating a *new* task with the next date when the current one
///    is completed, so from the API's side every task is a plain task with a
///    stable `gid`: the queue's external id needs no occurrence suffix, and
///    `uncomplete` really does reopen the same task. What it cannot do is
///    remove the next occurrence Asana spawned — that half is stated in the
///    connector, not hidden.
/// 7. **Verified live (junk and missing tokens, 2026-09-04):** Asana answers
///    **401 `{"errors":[{"message":"Not Authorized", …}]}`** for a missing
///    token and a wrong one alike, in JSON — so `problem` reads the message
///    out rather than pasting the envelope, and cannot claim to know which.
enum AsanaAPI {

    static let base = "https://app.asana.com/api/1.0"

    /// Asana's page cap: `limit` "must be between 1 and 100".
    static let pageLimit = 100

    /// The task fields the queue reads. `GET /tasks` returns compact objects
    /// (`gid`, `name`, `resource_type`, `resource_subtype`) unless asked;
    /// `projects.name` is the dotted opt-in form for a nested compact.
    static let taskFields =
        "name,notes,completed,due_on,due_at,created_at,modified_at,permalink_url,resource_subtype,projects.name"

    // MARK: Wire types

    /// Every Asana list response: `data` plus `next_page`, which is `null`
    /// on the last page — the **only** end-of-list signal.
    struct Envelope<Element: Decodable & Sendable>: Decodable, Sendable {
        var data: [Element]
        var nextPage: NextPage?

        enum CodingKeys: String, CodingKey {
            case data
            case nextPage = "next_page"
        }
    }

    struct NextPage: Decodable, Sendable {
        var offset: String?
    }

    struct Workspace: Decodable, Sendable {
        var gid: String
        var name: String
    }

    /// A project — Asana's word for what `TodoScope` calls a list. `archived`
    /// is opt-in on the wire; a missing value is treated as live.
    struct Project: Decodable, Sendable, Equatable {
        var gid: String
        var name: String
        var archived: Bool?

        var isUsable: Bool { archived != true }
    }

    /// A task, as `GET /tasks?opt_fields=…` returns it.
    ///
    /// Named `TaskEntry` for the same reason as Todoist's: `Task` is Swift's
    /// concurrency type, and shadowing it inside an actor is a trap.
    struct TaskEntry: Decodable, Sendable {
        var gid: String
        var name: String
        var notes: String?
        var completed: Bool?
        var dueOn: String?
        var dueAt: String?
        var createdAt: String?
        var modifiedAt: String?
        var permalinkUrl: String?
        var resourceSubtype: String?
        var projects: [Project]?

        enum CodingKeys: String, CodingKey {
            case gid, name, notes, completed, projects
            case dueOn = "due_on"
            case dueAt = "due_at"
            case createdAt = "created_at"
            case modifiedAt = "modified_at"
            case permalinkUrl = "permalink_url"
            case resourceSubtype = "resource_subtype"
        }

        /// `completed_since=now` is documented to exclude completed tasks,
        /// but this is a `.remoteTruth` source and one stale completed task
        /// is a row that will not die — belt and braces, as in Todoist.
        var isActive: Bool { completed != true }
    }

    /// `{"errors":[{"message":"Not Authorized","help":"…"}]}`.
    struct ErrorEnvelope: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            var message: String?
        }
        var errors: [Entry]?
    }

    // MARK: URLs

    static func workspacesURL(offset: String?) -> URL? {
        listURL(path: "/workspaces", items: [], offset: offset)
    }

    /// `GET /tasks?assignee=me&workspace=…&completed_since=now` — the
    /// due-window mode, one request per workspace.
    ///
    /// **Deliberately over-fetches.** There is no due-date parameter on this
    /// endpoint, so it returns every open task assigned to you and
    /// `TodoScope.accepts` narrows to the window — the same shape Todoist's
    /// `overdue | today | tomorrow` query has, with the same reason: the
    /// local clock is authoritative, not the account's.
    static func myTasksURL(workspace: String, offset: String?) -> URL? {
        listURL(
            path: "/tasks",
            items: [
                URLQueryItem(name: "assignee", value: "me"),
                URLQueryItem(name: "workspace", value: workspace),
                URLQueryItem(name: "completed_since", value: "now"),
                URLQueryItem(name: "opt_fields", value: taskFields),
            ],
            offset: offset)
    }

    /// `GET /tasks?project=…&completed_since=now` — the chosen-projects
    /// mode. No `assignee`: the spec allows exactly one of `project` or
    /// `assignee`+`workspace`, so this is everyone's open tasks in the
    /// project, and the field help says so.
    static func projectTasksURL(project: String, offset: String?) -> URL? {
        listURL(
            path: "/tasks",
            items: [
                URLQueryItem(name: "project", value: project),
                URLQueryItem(name: "completed_since", value: "now"),
                URLQueryItem(name: "opt_fields", value: taskFields),
            ],
            offset: offset)
    }

    /// `GET /projects?workspace=…&archived=false`.
    static func projectsURL(workspace: String, offset: String?) -> URL? {
        listURL(
            path: "/projects",
            items: [
                URLQueryItem(name: "workspace", value: workspace),
                URLQueryItem(name: "archived", value: "false"),
                URLQueryItem(name: "opt_fields", value: "name,archived"),
            ],
            offset: offset)
    }

    private static func listURL(
        path: String, items: [URLQueryItem], offset: String?
    ) -> URL? {
        var components = URLComponents(string: base + path)
        components?.queryItems =
            items + [URLQueryItem(name: "limit", value: String(pageLimit))]
            + (offset.map { [URLQueryItem(name: "offset", value: $0)] } ?? [])
        return components?.url
    }

    /// `PUT /tasks/{gid}`. The gid is percent-encoded even though Asana's
    /// are digits: it comes back out of a payload round-tripped through the
    /// store, and interpolating stored data into a URL is the habit the
    /// 2026-08-23 audit flagged. `.alphanumerics` rather than
    /// `.urlPathAllowed`, which lets `/` through and would turn a malformed
    /// id into a different path.
    static func taskURL(gid: String) -> URL? {
        guard
            let escaped = gid.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics), !escaped.isEmpty
        else { return nil }
        return URL(string: "\(base)/tasks/\(escaped)")
    }

    /// The body for complete / reopen: `{"data":{"completed":true}}`.
    static func completionBody(completed: Bool) -> Data {
        Data(#"{"data":{"completed":\#(completed ? "true" : "false")}}"#.utf8)
    }

    // MARK: Dates

    /// `due_at` wins when present (a timed task); else `due_on` is an
    /// all-day task anchored to local midnight, which is what
    /// `TodoItemMapper.isOverdue` expects of one.
    static func parseDue(dueOn: String?, dueAt: String?) -> (date: Date, isAllDay: Bool)? {
        if let dueAt, !dueAt.isEmpty, let instant = ISO8601Timestamp.date(from: dueAt) {
            return (instant, false)
        }
        if let dueOn, !dueOn.isEmpty, let day = dayFormatter.date(from: dueOn) {
            return (day, true)
        }
        return nil
    }

    private nonisolated(unsafe) static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // POSIX locale so a user on a non-Gregorian calendar still parses the
        // wire format; `Calendar.current` is used wherever the *user's* day
        // matters.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: Mapping

    /// Wire task → the provider-agnostic type everything else works on.
    ///
    /// `preferring` is the user's chosen project names: a task in several
    /// projects is labelled with the one the user asked for when there is
    /// one, so `TodoScope.accepts` sees the same name whichever request
    /// fetched it. Otherwise the first project, or nil for a task that lives
    /// only in My Tasks.
    static func task(from wire: TaskEntry, preferring names: [String]) -> TodoTask {
        let due = parseDue(dueOn: wire.dueOn, dueAt: wire.dueAt)
        let notes = wire.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TodoTask(
            providerID: wire.gid,
            title: wire.name,
            notes: notes?.isEmpty == false ? notes : nil,
            listName: listName(for: wire.projects, preferring: names),
            due: due?.date,
            isAllDay: due?.isAllDay ?? false,
            // Asana has no priority field; see the header.
            priority: .none,
            // And no recurrence field: a repeating task is a new task each
            // time, so the stable gid is the whole identity.
            isRecurring: false,
            createdAt: wire.createdAt.flatMap(ISO8601Timestamp.date(from:)),
            modifiedAt: wire.modifiedAt.flatMap(ISO8601Timestamp.date(from:)),
            deepLink: wire.permalinkUrl?.isEmpty == false ? wire.permalinkUrl : nil)
    }

    static func listName(for projects: [Project]?, preferring names: [String]) -> String? {
        guard let projects, !projects.isEmpty else { return nil }
        if let chosen = projects.first(where: { project in
            names.contains { $0.caseInsensitiveCompare(project.name) == .orderedSame }
        }) {
            return chosen.name
        }
        return projects.first?.name
    }

    // MARK: Errors

    /// Asana's own sentence, out of its JSON envelope — "Not Authorized",
    /// "project: Missing input" — or nil when the body is not that shape.
    static func message(in body: Data) -> String? {
        guard
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
            let first = envelope.errors?.first?.message?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !first.isEmpty
        else { return nil }
        return first
    }

    /// What went wrong, in words that say what to do about it (rule 5). A
    /// to-do source that silently returns nothing is indistinguishable from
    /// a day with nothing due.
    static func problem(forHTTPStatus status: Int, body: Data, retryAfter: String?) -> String {
        let said = message(in: body).map { " Asana said: \($0)." } ?? ""
        switch status {
        case 401:
            // Verified 2026-09-04: identical body for a missing and a wrong
            // token, so this cannot claim to know which.
            return
                "Asana rejected the personal access token (401). It answers the same way for a missing, mistyped or revoked token — create a new one in the developer console and paste the whole thing.\(said)"
        case 402:
            return
                "Asana says this needs a paid plan (402). Nothing this source asks for should, so if it persists, report it.\(said)"
        case 403:
            return
                "Asana refused the request (403). The token works but is not allowed to see this workspace or project — if it came from a different account, replace it in Settings › Sources.\(said)"
        case 404:
            return
                "Asana has no such task or project (404). It was probably deleted in Asana; the next refresh will clear the row.\(said)"
        case 400:
            return
                "Asana rejected the request (400). If you changed the projects this source watches, one of them may no longer exist — reopen it in Settings › Sources.\(said)"
        case 429:
            let wait = retryAfter.map { " Asana asked us to wait \($0)s." } ?? ""
            return
                "Asana rate-limited the request (429).\(wait) Polling backs off on its own; if it keeps happening, watch fewer projects.\(said)"
        case 500...599:
            return
                "Asana is having trouble (\(status)). Nothing to do at this end — the next refresh will try again.\(said)"
        default:
            return "Asana returned an unexpected status \(status).\(said)"
        }
    }
}
