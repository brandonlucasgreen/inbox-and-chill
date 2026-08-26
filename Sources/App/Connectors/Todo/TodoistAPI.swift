import Foundation

/// Everything about Todoist's REST API that does not need a network call:
/// the wire types, the URLs, the date parsing, and the error wording.
///
/// Split out from `TodoistConnector` for CLAUDE.md rule 6 — the connector is
/// an actor whose real work needs the network and the Keychain, so every
/// decision worth testing lives here as a `nonisolated static` pure function.
///
/// ## Which API this is
///
/// The **unified v1 API**, `https://api.todoist.com/api/v1`. Todoist replaced
/// REST v2 and Sync v9 with it, and the two older bases are gone — a
/// connector written against `/rest/v2/tasks` would 404. Shapes below are
/// taken from Todoist's published OpenAPI document (fetched 2026-08-26), not
/// from memory, because three details in it are counter-intuitive:
///
/// 1. **Task ids are opaque alphanumeric strings** (`6XGgmFVcrG5RRjVr`), not
///    the integers the older API handed out. `TodoItemMapper`'s `#` occurrence
///    separator is still safe — the character class is `[0-9a-zA-Z]` — but the
///    comment there claiming Todoist ids are digits is out of date.
/// 2. **There is no `url` field** on a task, so the deep link is constructed.
/// 3. **`priority: 1` is the default every task has**, and 4 is urgent — the
///    inverse of EventKit *and* the inverse of the labels Todoist's own UI
///    shows (its "P1" is `priority: 4`). See `TodoPriority.fromTodoist`.
enum TodoistAPI {

    static let base = "https://api.todoist.com/api/v1"

    /// Todoist's page cap. The OpenAPI document gives `maximum: 200` for
    /// `limit` on every paginated endpoint, and defaults it to 50 — so asking
    /// for 200 is a fourfold cut in requests, not a gamble.
    static let pageLimit = 200

    // MARK: Wire types

    /// One page of anything. Todoist pages by opaque cursor: `next_cursor` is
    /// `null` on the last page, which is the *only* end-of-list signal — a
    /// short page does not mean the end.
    struct Page<Element: Decodable & Sendable>: Decodable, Sendable {
        var results: [Element]
        var nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case results
            case nextCursor = "next_cursor"
        }
    }

    /// A task, as `GET /tasks` and `GET /tasks/filter` return it.
    ///
    /// Named `TaskEntry` rather than `Task` on purpose: `Task` is Swift's
    /// concurrency type, and a nested shadow of it inside an actor is a trap
    /// waiting for whoever next writes `Task { … }` in this file.
    ///
    /// Both endpoints answer with the same `ItemSyncView` shape, which is why
    /// the two scope modes can be unioned without a second decoder.
    struct TaskEntry: Decodable, Sendable {
        var id: String
        var content: String
        var description: String?
        var projectId: String?
        var due: Due?
        var priority: Int?
        var addedAt: String?
        var updatedAt: String?
        var checked: Bool?
        var isDeleted: Bool?

        enum CodingKeys: String, CodingKey {
            case id, content, description, due, priority, checked
            case projectId = "project_id"
            case addedAt = "added_at"
            case updatedAt = "updated_at"
            case isDeleted = "is_deleted"
        }

        /// Active means: not ticked off and not in the trash.
        ///
        /// Both endpoints are documented to return only active tasks, so this
        /// is belt and braces — but it is cheap belt and braces guarding a
        /// `.remoteTruth` source, where one stale completed task showing up
        /// is a row that will not die.
        var isActive: Bool { checked != true && isDeleted != true }
    }

    /// Todoist's due object.
    ///
    /// `date` carries **both** shapes — `2026-08-26` for an all-day task and a
    /// full timestamp for a timed one. There is no separate `datetime` field
    /// in this view, so the string's own form is the all-day discriminator.
    /// That is the direct analogue of EventKit announcing all-day by leaving
    /// `dueDateComponents.hour` nil.
    struct Due: Decodable, Sendable {
        var date: String?
        var isRecurring: Bool?
        var timezone: String?
        var string: String?

        enum CodingKeys: String, CodingKey {
            case date, timezone, string
            case isRecurring = "is_recurring"
        }
    }

    /// A project — Todoist's word for what `TodoScope` calls a list.
    struct Project: Decodable, Sendable {
        var id: String
        var name: String
        var isArchived: Bool?
        var isDeleted: Bool?

        enum CodingKeys: String, CodingKey {
            case id, name
            case isArchived = "is_archived"
            case isDeleted = "is_deleted"
        }

        var isUsable: Bool { isArchived != true && isDeleted != true }
    }

    // MARK: URLs

    /// `GET /tasks/filter` — the due-window mode.
    ///
    /// The filter language is the only way to ask Todoist a due-date question;
    /// `GET /tasks` has no due parameter at all.
    static func filterURL(query: String, cursor: String?) -> URL? {
        var components = URLComponents(string: "\(base)/tasks/filter")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(pageLimit)),
        ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return components?.url
    }

    /// The due-window query.
    ///
    /// **Deliberately wider than the window it serves.** Todoist evaluates
    /// `today` against the timezone set in the *Todoist account*, while
    /// `TodoScope.dueWindowEnd()` uses this Mac's calendar. When the two
    /// disagree — travelling, or an account left on an old timezone — a task
    /// that is genuinely due today here can fall outside Todoist's `today`,
    /// and a missing to-do is exactly the silent drop this app exists to
    /// prevent. Asking for `tomorrow` as well costs one extra page at worst
    /// and makes the local clock authoritative, because `TodoScope.accepts`
    /// re-filters every task before it becomes an item. Over-fetch, then let
    /// the one documented gate narrow it.
    static let dueWindowQuery = "overdue | today | tomorrow"

    /// `GET /tasks?project_id=…` — the chosen-projects mode.
    static func projectTasksURL(projectID: String, cursor: String?) -> URL? {
        var components = URLComponents(string: "\(base)/tasks")
        components?.queryItems = [
            URLQueryItem(name: "project_id", value: projectID),
            URLQueryItem(name: "limit", value: String(pageLimit)),
        ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return components?.url
    }

    static func projectsURL(cursor: String?) -> URL? {
        var components = URLComponents(string: "\(base)/projects")
        components?.queryItems = [
            URLQueryItem(name: "limit", value: String(pageLimit))
        ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return components?.url
    }

    /// `POST /tasks/{id}/close` and `/reopen`.
    ///
    /// The id is percent-encoded even though Todoist's ids are alphanumeric:
    /// this one comes back out of a payload that has been round-tripped
    /// through the store, and building a URL by interpolation is the habit
    /// the 2026-08-23 security audit flagged in two other connectors.
    static func taskActionURL(taskID: String, action: String) -> URL? {
        guard
            let escaped = taskID.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed), !escaped.isEmpty
        else { return nil }
        return URL(string: "\(base)/tasks/\(escaped)/\(action)")
    }

    /// Where a row opens.
    ///
    /// Constructed, because the task object carries no `url`. Deliberately
    /// `https` rather than a `todoist://` scheme: https is already in
    /// `AppState.openable`'s allowlist, so this needs no widening of the
    /// surface that audit closed, and it resolves for someone who only uses
    /// the web app. If the Todoist desktop app is installed and claims its own
    /// links, macOS routes it there; **that has not been verified here.**
    static func deepLink(taskID: String) -> String {
        "https://app.todoist.com/app/task/\(taskID)"
    }

    // MARK: Dates

    /// Parses `due.date` into an instant plus whether it is all-day.
    ///
    /// Three shapes, all of which Todoist really sends:
    ///
    /// - `2026-08-26` — all-day. Anchored to local midnight, which is what
    ///   `TodoItemMapper.isOverdue` expects of an all-day task.
    /// - `2026-08-26T14:30:00` — a *floating* time, with no zone designator.
    ///   `ISO8601DateFormatter` rejects this outright, which is why this
    ///   function exists rather than deferring to `ISO8601Timestamp`.
    /// - `2026-08-26T14:30:00.000000Z` — absolute.
    static func parseDue(_ raw: String?) -> (date: Date, isAllDay: Bool)? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.count == 10, let day = dayFormatter.date(from: raw) {
            return (day, true)
        }
        if let absolute = parseTimestamp(raw) { return (absolute, false) }
        if let floating = floatingFormatter.date(from: String(raw.prefix(19))) {
            return (floating, false)
        }
        return nil
    }

    /// `added_at` / `updated_at`, and the absolute branch of `parseDue`.
    ///
    /// Todoist sends **six** fractional digits (`.000000Z`).
    /// `ISO8601DateFormatter.withFractionalSeconds` is specified around three
    /// and cannot be relied on past that, so the fraction is normalised before
    /// the shared parser sees it. Same class of trap as the Sentry timestamps
    /// that `ISO8601Timestamp` was written for — one layer further down.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = ISO8601Timestamp.date(from: raw) { return date }
        let trimmed = normalisingFraction(raw)
        if trimmed != raw, let date = ISO8601Timestamp.date(from: trimmed) {
            return date
        }
        return nil
    }

    /// Cuts a sub-second fraction down to three digits, leaving the zone
    /// designator attached.
    static func normalisingFraction(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }
        let afterDot = raw.index(after: dot)
        guard
            let endOfDigits = raw[afterDot...].firstIndex(where: {
                !$0.isNumber
            })
        else { return raw }
        let digits = raw[afterDot..<endOfDigits]
        guard digits.count > 3 else { return raw }
        return String(raw[..<afterDot]) + digits.prefix(3)
            + String(raw[endOfDigits...])
    }

    private nonisolated(unsafe) static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // POSIX locale so a user on a non-Gregorian calendar still parses the
        // wire format; the app's own `Calendar.current` is used everywhere the
        // *user's* idea of a day matters.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private nonisolated(unsafe) static let floatingFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    // MARK: Mapping

    /// Wire task → the provider-agnostic type everything else works on.
    ///
    /// `projectNames` resolves `project_id` to something a human recognises;
    /// an id we have no name for yields `nil` rather than a raw id in the
    /// row's sender slot.
    static func task(from wire: TaskEntry, projectNames: [String: String]) -> TodoTask {
        let due = parseDue(wire.due?.date)
        let notes = wire.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TodoTask(
            providerID: wire.id,
            title: wire.content,
            notes: notes?.isEmpty == false ? notes : nil,
            listName: wire.projectId.flatMap { projectNames[$0] },
            due: due?.date,
            isAllDay: due?.isAllDay ?? false,
            priority: TodoPriority.fromTodoist(wire.priority ?? 1),
            isRecurring: wire.due?.isRecurring ?? false,
            createdAt: parseTimestamp(wire.addedAt),
            modifiedAt: parseTimestamp(wire.updatedAt),
            deepLink: deepLink(taskID: wire.id))
    }

    // MARK: Errors

    /// What went wrong, in words that say what to do about it (rule 5).
    ///
    /// A to-do source that silently returns nothing is indistinguishable from
    /// a day with nothing due, which is the failure this whole file is written
    /// against.
    static func problem(forHTTPStatus status: Int, body: String?, retryAfter: String?)
        -> String
    {
        let snippet = body.flatMap { $0.isEmpty ? nil : " \($0)" } ?? ""
        switch status {
        case 401:
            return
                "Todoist rejected the API token (401). Copy it again from Todoist → Settings → Integrations → Developer; the token is the whole line, with no `Bearer` in front of it.\(snippet)"
        case 403:
            return
                "Todoist refused the request (403). The token is being read but is not allowed to see this — if it came from a different account, replace it in Settings › Sources.\(snippet)"
        case 404:
            return
                "Todoist has no such task or project (404). It was probably deleted in Todoist; the next refresh will clear the row.\(snippet)"
        case 400:
            return
                "Todoist rejected the request (400). If you changed the projects this source watches, one of them may no longer exist — reopen it in Settings › Sources.\(snippet)"
        case 429:
            let wait = retryAfter.map { " Todoist asked us to wait \($0)s." } ?? ""
            return
                "Todoist rate-limited the request (429).\(wait) Polling backs off on its own; if it keeps happening, watch fewer projects.\(snippet)"
        case 500...599:
            return
                "Todoist is having trouble (\(status)). Nothing to do at this end — the next refresh will try again.\(snippet)"
        default:
            return "Todoist returned an unexpected status \(status).\(snippet)"
        }
    }
}
