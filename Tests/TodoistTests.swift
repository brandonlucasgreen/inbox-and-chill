import Foundation
import Testing

@testable import InboxAndChill

// MARK: - Sources/App/Connectors/Todo/Todoist*
//
// Todoist is the second provider behind the `TodoTask` seam, so most of what
// makes a to-do behave correctly in the queue is already pinned by
// `TodoMappingTests` and is not re-tested here. What *is* here is everything
// specific to Todoist's wire format — and the three facts in it that would
// each fail silently:
//
// 1. `priority: 1` is the value every untouched task carries. Reading it as a
//    real priority would make the high-signal badge fire on the whole account.
// 2. `due.date` carries both an all-day date and a timed one, and the timed
//    form is sometimes *floating* (no zone), which `ISO8601DateFormatter`
//    refuses outright. Getting this wrong loses every timed task's due date.
// 3. `next_cursor` is the only end-of-list signal. Treating a short page as
//    the end would hand `.remoteTruth` a truncated snapshot, which archives
//    every task past the cut.
//
// Shapes come from Todoist's published OpenAPI document, fetched 2026-08-26.
// Nothing here has met a live account — see the note in `TodoistConnector`.

private func decodeTask(_ json: String) throws -> TodoistAPI.TaskEntry {
    try JSONDecoder().decode(
        TodoistAPI.TaskEntry.self, from: Data(json.utf8))
}

/// A task as `GET /tasks/filter` really answers, trimmed to the fields the
/// connector reads. Written out as JSON rather than built as a struct so the
/// snake_case `CodingKeys` are actually exercised — a typo'd key would
/// otherwise decode to `nil` and be invisible.
private let sampleTaskJSON = """
    {
      "id": "6XGgmFVcrG5RRjVr",
      "user_id": "1234567",
      "project_id": "6XGgm6PHrGgMpCFX",
      "content": "Water the plants",
      "description": "  the big one by the window  ",
      "priority": 4,
      "checked": false,
      "is_deleted": false,
      "added_at": "2026-08-20T09:15:00.000000Z",
      "updated_at": "2026-08-24T11:30:00.123456Z",
      "due": {
        "date": "2026-08-26",
        "is_recurring": true,
        "string": "every day",
        "lang": "en"
      }
    }
    """

struct TodoistWireDecodingTests {

    @Test("The snake_case keys the connector reads all decode")
    func decodesEveryFieldItUses() throws {
        let wire = try decodeTask(sampleTaskJSON)
        #expect(wire.id == "6XGgmFVcrG5RRjVr")
        #expect(wire.content == "Water the plants")
        #expect(wire.projectId == "6XGgm6PHrGgMpCFX")
        #expect(wire.priority == 4)
        #expect(wire.checked == false)
        #expect(wire.isDeleted == false)
        #expect(wire.addedAt == "2026-08-20T09:15:00.000000Z")
        #expect(wire.updatedAt == "2026-08-24T11:30:00.123456Z")
        #expect(wire.due?.date == "2026-08-26")
        #expect(wire.due?.isRecurring == true)
        #expect(wire.isActive)
    }

    @Test("A task with no due date, description or priority still decodes")
    func decodesSparseTask() throws {
        let wire = try decodeTask(
            #"{"id":"abc","content":"Something","project_id":"p1"}"#)
        #expect(wire.due == nil)
        #expect(wire.description == nil)
        #expect(wire.priority == nil)
        // Absent `checked`/`is_deleted` must read as active, not as unknown —
        // a `.remoteTruth` source that dropped these would archive live rows.
        #expect(wire.isActive)
    }

    @Test("Completed and trashed tasks are not active")
    func inactiveTasksAreRejected() throws {
        let done = try decodeTask(#"{"id":"a","content":"x","checked":true}"#)
        let gone = try decodeTask(#"{"id":"b","content":"x","is_deleted":true}"#)
        #expect(!done.isActive)
        #expect(!gone.isActive)
    }

    @Test("A page carries its cursor, and null means the end")
    func pageEnvelopeDecodes() throws {
        let more = try JSONDecoder().decode(
            TodoistAPI.Page<TodoistAPI.TaskEntry>.self,
            from: Data(
                #"{"results":[{"id":"a","content":"x"}],"next_cursor":"aa.bb"}"#
                    .utf8))
        #expect(more.results.count == 1)
        #expect(more.nextCursor == "aa.bb")

        let last = try JSONDecoder().decode(
            TodoistAPI.Page<TodoistAPI.TaskEntry>.self,
            from: Data(#"{"results":[],"next_cursor":null}"#.utf8))
        // This is the *only* end-of-list signal Todoist gives; a short page is
        // not one. `TodoistConnector.paged` reports the walk incomplete when
        // it stops with a cursor still in hand, so `.remoteTruth` cannot
        // archive the tail it never read.
        #expect(last.nextCursor == nil)
    }

    @Test("Archived and deleted projects are not offered or matched")
    func projectUsability() throws {
        let projects = try JSONDecoder().decode(
            TodoistAPI.Page<TodoistAPI.Project>.self,
            from: Data(
                """
                {"results":[
                  {"id":"1","name":"Work","is_archived":false,"is_deleted":false},
                  {"id":"2","name":"Old","is_archived":true,"is_deleted":false},
                  {"id":"3","name":"Gone","is_archived":false,"is_deleted":true},
                  {"id":"4","name":"Home"}
                ],"next_cursor":null}
                """.utf8))
        #expect(projects.results.filter(\.isUsable).map(\.name) == ["Work", "Home"])
    }
}

struct TodoistPriorityTests {

    @Test("Todoist's priority 1 is “no priority”, not “low”")
    func defaultPriorityIsNone() {
        // The load-bearing case. Every untouched Todoist task arrives as 1, so
        // reading it as a real priority would make `TodoItemMapper.highSignal`
        // — or any future priority sort — true of the entire account.
        #expect(TodoPriority.fromTodoist(1) == TodoPriority.none)
    }

    @Test("The scale is inverted relative to EventKit, and to Todoist's own UI")
    func priorityScale() {
        // Todoist's UI prints `priority: 4` as "P1". Both inversions live in
        // this one function so nothing downstream has to know about either.
        #expect(TodoPriority.fromTodoist(4) == .high)
        #expect(TodoPriority.fromTodoist(3) == .medium)
        #expect(TodoPriority.fromTodoist(2) == .low)
        // EventKit's 1 is *high*; Todoist's is none. Same integer, opposite
        // meaning — which is exactly why there are two mapping functions.
        #expect(TodoPriority.fromEventKit(1) == .high)
    }

    @Test("A value outside the scale is not a priority")
    func unknownPriority() {
        #expect(TodoPriority.fromTodoist(0) == TodoPriority.none)
        #expect(TodoPriority.fromTodoist(9) == TodoPriority.none)
    }
}

struct TodoistDateTests {

    @Test("A bare date is all-day, anchored to local midnight")
    func allDayDue() throws {
        let parsed = try #require(TodoistAPI.parseDue("2026-08-26"))
        #expect(parsed.isAllDay)
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour], from: parsed.date)
        #expect(parts.year == 2026 && parts.month == 8 && parts.day == 26)
        // Local midnight is what `TodoItemMapper.isOverdue` expects of an
        // all-day task — it waits for the day to end rather than treating
        // 00:00 as already late.
        #expect(parts.hour == 0)
        #expect(
            !TodoItemMapper.isOverdue(
                due: parsed.date, isAllDay: true,
                now: parsed.date.addingTimeInterval(3600)))
    }

    @Test("A floating datetime parses, though ISO8601DateFormatter refuses it")
    func floatingDue() throws {
        // No zone designator. This is the shape that made a hand-rolled parser
        // necessary: `ISO8601Timestamp` returns nil for it, so deferring to
        // the shared helper alone would silently drop the due date of every
        // timed task and leave it looking undated.
        #expect(ISO8601Timestamp.date(from: "2026-08-26T14:30:00") == nil)

        let parsed = try #require(TodoistAPI.parseDue("2026-08-26T14:30:00"))
        #expect(!parsed.isAllDay)
        let parts = Calendar.current.dateComponents(
            [.hour, .minute], from: parsed.date)
        #expect(parts.hour == 14 && parts.minute == 30)
    }

    @Test("An absolute datetime parses at the instant it names")
    func absoluteDue() throws {
        let parsed = try #require(
            TodoistAPI.parseDue("2026-08-26T14:30:00.000000Z"))
        #expect(!parsed.isAllDay)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.hour, .minute], from: parsed.date)
        #expect(parts.hour == 14 && parts.minute == 30)
    }

    @Test("Six fractional digits still parse")
    func microsecondTimestamps() throws {
        // Todoist sends microseconds. `ISO8601DateFormatter.withFractionalSeconds`
        // is specified around three digits, so the fraction is normalised
        // first — same class of trap as the Sentry timestamps, one layer down.
        let parsed = try #require(
            TodoistAPI.parseTimestamp("2026-08-24T11:30:00.123456Z"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents(
            [.year, .month, .day, .hour, .minute], from: parsed)
        #expect(parts.year == 2026 && parts.month == 8 && parts.day == 24)
        #expect(parts.hour == 11 && parts.minute == 30)
    }

    @Test("Normalising a fraction leaves the zone designator attached")
    func fractionNormalisation() {
        #expect(
            TodoistAPI.normalisingFraction("2026-08-24T11:30:00.123456Z")
                == "2026-08-24T11:30:00.123Z")
        #expect(
            TodoistAPI.normalisingFraction("2026-08-24T11:30:00.12+01:00")
                == "2026-08-24T11:30:00.12+01:00")
        #expect(
            TodoistAPI.normalisingFraction("2026-08-24T11:30:00Z")
                == "2026-08-24T11:30:00Z")
    }

    @Test("Nothing, or nonsense, is no due date rather than a wrong one")
    func unparseableDue() {
        #expect(TodoistAPI.parseDue(nil) == nil)
        #expect(TodoistAPI.parseDue("") == nil)
        #expect(TodoistAPI.parseDue("next tuesday") == nil)
        #expect(TodoistAPI.parseTimestamp("not a date") == nil)
    }
}

struct TodoistMappingTests {

    @Test("A wire task becomes a TodoTask with the fields the queue reads")
    func mapsToTodoTask() throws {
        let wire = try decodeTask(sampleTaskJSON)
        let task = TodoistAPI.task(
            from: wire, projectNames: ["6XGgm6PHrGgMpCFX": "Home"])

        #expect(task.providerID == "6XGgmFVcrG5RRjVr")
        #expect(task.title == "Water the plants")
        // Trimmed, and never truncated — this is what `D` reveals, and the
        // Slack-saves bug was a connector that stored no body at all.
        #expect(task.notes == "the big one by the window")
        #expect(task.listName == "Home")
        #expect(task.isAllDay)
        #expect(task.isRecurring)
        #expect(task.priority == .high)
        #expect(task.deepLink == "https://app.todoist.com/app/task/6XGgmFVcrG5RRjVr")
        #expect(task.modifiedAt == TodoistAPI.parseTimestamp(wire.updatedAt))
        #expect(task.createdAt == TodoistAPI.parseTimestamp(wire.addedAt))
    }

    @Test("An unknown project id leaves the sender slot empty, not raw")
    func unresolvedProjectName() throws {
        let wire = try decodeTask(sampleTaskJSON)
        let task = TodoistAPI.task(from: wire, projectNames: [:])
        // A raw `6XGgm6PHrGgMpCFX` in the row's sender slot would be worse
        // than nothing there.
        #expect(task.listName == nil)
    }

    @Test("An empty description is no body, not an empty one")
    func blankDescription() throws {
        let wire = try decodeTask(
            #"{"id":"a","content":"x","description":"   "}"#)
        #expect(TodoistAPI.task(from: wire, projectNames: [:]).notes == nil)
    }

    @Test("A repeating task's queue id carries the occurrence day")
    func recurringTaskGetsOccurrenceID() throws {
        // The inherited half, re-checked through the Todoist path because it
        // is the one that fails silently: Todoist's `close` advances a
        // recurring task and keeps its id, so without the day suffix a daily
        // task would be completed once and never seen again.
        let wire = try decodeTask(sampleTaskJSON)
        let task = TodoistAPI.task(from: wire, projectNames: [:])
        let item = TodoItemMapper.remoteItem(from: task, now: .now)
        #expect(item.externalID == "6XGgmFVcrG5RRjVr#2026-08-26")
        // And the write-through still reaches Todoist's own id.
        #expect(
            TodoPayload.providerID(
                externalID: item.externalID, payload: item.payload)
                == "6XGgmFVcrG5RRjVr")
    }

    @Test("occurredAt is when the task changed, never when it is due")
    func occurredAtIsModifiedAt() throws {
        let wire = try decodeTask(sampleTaskJSON)
        let task = TodoistAPI.task(from: wire, projectNames: [:])
        let item = TodoItemMapper.remoteItem(from: task, now: .now)
        // If this were the due date, dismissing a task due later today would
        // be undone by the very next poll — `Store.resurrectIfNeeded` revives
        // on `occurredAt > doneAt`.
        #expect(item.occurredAt == TodoistAPI.parseTimestamp(wire.updatedAt))
        #expect(item.occurredAt != task.due)
    }
}

struct TodoistRequestTests {

    @Test("The due-window query asks wider than the window, on purpose")
    func dueWindowQueryIsWide() {
        // Todoist evaluates `today` in the account's timezone, not this Mac's.
        // Over-fetching and letting `TodoScope.accepts` narrow it is what keeps
        // the local clock authoritative — a task dropped for being in the
        // wrong timezone is exactly the silent loss this app exists to stop.
        #expect(TodoistAPI.dueWindowQuery.contains("overdue"))
        #expect(TodoistAPI.dueWindowQuery.contains("today"))
        #expect(TodoistAPI.dueWindowQuery.contains("tomorrow"))
        // The comma operator is not supported by this endpoint; `|` is.
        #expect(!TodoistAPI.dueWindowQuery.contains(","))
    }

    @Test("Requests go to the v1 base with the query safely encoded")
    func urlsAreWellFormed() throws {
        let filter = try #require(
            TodoistAPI.filterURL(query: "overdue | today", cursor: nil))
        #expect(filter.absoluteString.hasPrefix("https://api.todoist.com/api/v1/tasks/filter"))
        // `|` and spaces must survive as query-encoded, not split the URL.
        let items = try #require(
            URLComponents(url: filter, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "query" }?.value == "overdue | today")
        #expect(items.first { $0.name == "limit" }?.value == "200")
        #expect(!items.contains { $0.name == "cursor" })

        let paged = try #require(
            TodoistAPI.filterURL(query: "today", cursor: "aa.bb"))
        let pagedItems = try #require(
            URLComponents(url: paged, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(pagedItems.first { $0.name == "cursor" }?.value == "aa.bb")

        let project = try #require(
            TodoistAPI.projectTasksURL(projectID: "6XGgm", cursor: nil))
        let projectItems = try #require(
            URLComponents(url: project, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(projectItems.first { $0.name == "project_id" }?.value == "6XGgm")
    }

    @Test("Close and reopen address the task by an escaped id")
    func actionURLs() throws {
        let close = try #require(
            TodoistAPI.taskActionURL(taskID: "6XGgmFVcrG5RRjVr", action: "close"))
        #expect(
            close.absoluteString
                == "https://api.todoist.com/api/v1/tasks/6XGgmFVcrG5RRjVr/close")
        let reopen = try #require(
            TodoistAPI.taskActionURL(taskID: "6XGgmFVcrG5RRjVr", action: "reopen"))
        #expect(reopen.absoluteString.hasSuffix("/reopen"))
        // An id that could not be a path component yields nothing rather than
        // a URL that means something else — the habit the 2026-08-23 audit
        // asked for after finding interpolated URLs in two other connectors.
        #expect(TodoistAPI.taskActionURL(taskID: "", action: "close") == nil)
    }

    @Test("The deep link is https, which needs no widening of the allowlist")
    @MainActor
    func deepLinkIsAlreadyOpenable() throws {
        let raw = TodoistAPI.deepLink(taskID: "6XGgmFVcrG5RRjVr")
        let url = try #require(URL(string: raw))
        #expect(url.scheme == "https")
        // `AppState.openable` admits https for any source, so this connector
        // adds no new scheme to the surface that audit closed.
        #expect(
            AppState.openable(url, sourceKind: "todoist", payload: nil) == url)
    }
}

struct TodoistFailureTests {

    @Test("Every failure says what to do about it")
    func problemsAreActionable() {
        // Rule 5, and the sharpest case of it in the app: a to-do source that
        // returns nothing looks exactly like a day with nothing due.
        let unauthorised = TodoistAPI.problem(
            forHTTPStatus: 401, body: nil, retryAfter: nil)
        #expect(unauthorised.contains("401"))
        #expect(unauthorised.contains("Developer"))

        let rateLimited = TodoistAPI.problem(
            forHTTPStatus: 429, body: nil, retryAfter: "30")
        #expect(rateLimited.contains("30"))

        let down = TodoistAPI.problem(forHTTPStatus: 503, body: nil, retryAfter: nil)
        #expect(down.contains("503"))

        for status in [400, 401, 403, 404, 429, 500, 418] {
            let message = TodoistAPI.problem(
                forHTTPStatus: status, body: nil, retryAfter: nil)
            #expect(!message.isEmpty, "status \(status) has no message")
            #expect(message.contains("Todoist"), "status \(status)")
        }
    }

    @Test("A project that has been renamed away is named, not swallowed")
    func missingProjectsAreNamed() {
        let message = TodoistConnector.missingProjectsMessage(["Work", "Home"])
        #expect(message.contains("Work") && message.contains("Home"))
        #expect(message.contains("Settings"))
    }

    @Test("Undo on a repeating task admits what it cannot restore")
    func recurringUndoIsHonest() {
        // `close` rescheduled the task rather than completing it, so there is
        // nothing for `reopen` to undo and no call that brings the old date
        // back. Saying so beats an undo that half works in silence.
        let note = TodoistConnector.recurringUndoNote
        #expect(note.lowercased().contains("recurring"))
        #expect(note.contains("Todoist"))
    }
}

struct TodoistScopeTests {

    private func project(_ id: String, _ name: String, archived: Bool = false)
        throws -> TodoistAPI.Project
    {
        try JSONDecoder().decode(
            TodoistAPI.Project.self,
            from: Data(
                #"{"id":"\#(id)","name":"\#(name)","is_archived":\#(archived)}"#
                    .utf8))
    }

    @Test("Projects are matched by name, case-insensitively")
    func resolvesProjectsByName() throws {
        let all = [
            try project("1", "Work"), try project("2", "Home"),
            try project("3", "Archive", archived: true),
        ]
        let resolved = TodoistConnector.resolveProjects(
            named: ["work", "ARCHIVE"], in: all)
        // Case-insensitive so the stored spelling need not match exactly, and
        // archived projects are never resolved — their tasks are not open work.
        #expect(resolved.map(\.name) == ["Work"])
    }

    @Test("The generic scope treats projects exactly as it treats lists")
    func scopeIsProviderAgnostic() {
        // The whole claim of the `TodoTask` seam, checked rather than asserted:
        // nothing in `TodoScope` had to change for a second provider, so a
        // Todoist source configured from the `projects` field behaves
        // identically to a Reminders source configured from `lists`.
        let scope = TodoScope(
            includesDueWindow: false, listNames: TodoScope.parseListNames("Work, Home"),
            listsIncludeUndated: false)
        #expect(scope.listNames == ["Work", "Home"])
        #expect(scope.includesList("work"))

        let dated = TodoTask(
            providerID: "1", title: "x", listName: "Work", due: .now)
        let undated = TodoTask(providerID: "2", title: "y", listName: "Work")
        #expect(scope.accepts(dated))
        // Dated-only unless the toggle is on — Brandon's call, and the reason
        // a long backlog project doesn't bury every other source.
        #expect(!scope.accepts(undated))

        var permissive = scope
        permissive.listsIncludeUndated = true
        #expect(permissive.accepts(undated))
    }
}

struct TodoistWiringTests {

    @Test("The catalog entry offers both scope modes and one secret")
    func descriptorShape() throws {
        let todoist = try #require(ConnectorCatalog.descriptor(for: "todoist"))
        #expect(
            todoist.fields.map(\.key)
                == ["token", "dueToday", "projects", "projectsIncludeUndated"])
        #expect(todoist.fields.first { $0.key == "token" }?.isSecret == true)
        #expect(todoist.fields.first { $0.key == "dueToday" }?.defaultOn == true)
        // Off by default, for the same reason as Reminders: an undated backlog
        // buries everything else in the queue.
        #expect(
            todoist.fields.first { $0.key == "projectsIncludeUndated" }?.defaultOn
                == false)
        // It asks for a secret, so it owes the user setup steps —
        // `credentialSourcesExplainThemselves` enforces this across the
        // catalog, and this pins the link the steps refer to.
        #expect(!todoist.setupSteps.isEmpty)
        #expect(todoist.setupURL.contains("todoist.com"))
        // Unlike Reminders, a token can name any of several accounts.
        #expect(todoist.allowsMultiple)
    }

    @Test("Each fact appears once on the Todoist editor screen")
    func editorCopyDoesNotRepeatItself() throws {
        // The 2026-08-26 note: three explanatory surfaces per editor make it
        // easy to say the same thing four times. Guarding it here rather than
        // trusting a read-through, exactly as the Reminders screen does.
        let todoist = try #require(ConnectorCatalog.descriptor(for: "todoist"))
        let onScreen =
            todoist.authNote + todoist.setupSteps.joined()
            + todoist.fields.map(\.help).joined()
        let keychainMentions =
            onScreen.components(separatedBy: "Keychain").count - 1
        #expect(keychainMentions <= 1, "the token's storage has one home")
        let tokenPageMentions =
            onScreen.components(separatedBy: "Developer").count - 1
        #expect(tokenPageMentions <= 2, "where to find the token has one home")
    }

    @Test("The factory builds a Todoist connector with the configured scope")
    func factoryWiring() async throws {
        let config = SourceConfig(kind: "todoist", displayName: "Todoist")
        config.settings = [
            "dueToday": "false", "projects": "Work, Home",
            "projectsIncludeUndated": "true",
        ]
        let connector = try #require(ConnectorFactory.make(config: config))
        #expect(connector.sourceKind == "todoist")
        // The capability set *is* the dismiss-vs-complete feature: `E` writes
        // nothing remotely precisely because `.markDone` is absent, and `C`
        // exists precisely because `.completesTask` is present.
        #expect(connector.capabilities.contains(.completesTask))
        #expect(!connector.capabilities.contains(.markDone))
        #expect(connector.capabilities.contains(.remoteTruth))
    }

    @Test("A source asking for nothing says so instead of looking empty")
    func emptyScopeIsRefused() async throws {
        let config = SourceConfig(kind: "todoist", displayName: "Todoist")
        config.settings = ["dueToday": "false", "projects": ""]
        let connector = try #require(ConnectorFactory.make(config: config))
        // No network is reached: the guard fires before the token is read, so
        // this runs offline and in CI.
        await #expect(throws: (any Error).self) { try await connector.fetch() }
    }
}
