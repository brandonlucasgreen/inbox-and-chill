import Foundation
import Testing

@testable import InboxAndChill

// MARK: - Sources/App/Connectors/Todo/Asana*
//
// Asana is the third provider behind the `TodoTask` seam, so how a to-do
// behaves in the queue is already pinned by `TodoMappingTests`. What is here
// is everything specific to Asana's wire format, and the facts that would
// each fail silently:
//
// 1. `due_on` and `due_at` are two fields. Reading only one loses every
//    timed task's time, or every all-day task's date.
// 2. `next_page` is the only end-of-list signal. A short page is not the end.
// 3. Errors arrive as JSON `{"errors":[{"message":…}]}` — the real 401 body
//    is below, captured from a credential-less request on 2026-09-04 — and a
//    missing token and a wrong one are indistinguishable.
//
// Shapes come from Asana's OpenAPI document. **No request has been made with
// a real token** when this was written; these tests are the verification.

private func decodeTask(_ json: String) throws -> AsanaAPI.TaskEntry {
    try JSONDecoder().decode(AsanaAPI.TaskEntry.self, from: Data(json.utf8))
}

/// A task as `GET /tasks?opt_fields=…` returns it, with the snake_case keys
/// written out so a typo'd `CodingKey` decodes to nil visibly.
private let timedTaskJSON = """
    {
      "gid": "1204567890123456",
      "resource_type": "task",
      "resource_subtype": "default_task",
      "name": "Send the launch email",
      "notes": "  Draft is in the shared doc.  ",
      "completed": false,
      "due_on": "2026-09-05",
      "due_at": "2026-09-05T15:00:00.000Z",
      "created_at": "2026-08-30T09:15:00.123Z",
      "modified_at": "2026-09-03T11:30:00.456Z",
      "permalink_url": "https://app.asana.com/0/1201/1204567890123456",
      "projects": [
        { "gid": "1201", "resource_type": "project", "name": "Marketing" },
        { "gid": "1202", "resource_type": "project", "name": "Launch" }
      ]
    }
    """

@Suite("Asana wire decoding")
struct AsanaWireDecodingTests {

    @Test("The snake_case keys the connector reads all decode")
    func decodesDocumentedTask() throws {
        let task = try decodeTask(timedTaskJSON)
        #expect(task.gid == "1204567890123456")
        #expect(task.name == "Send the launch email")
        #expect(task.dueOn == "2026-09-05")
        #expect(task.dueAt == "2026-09-05T15:00:00.000Z")
        #expect(task.modifiedAt == "2026-09-03T11:30:00.456Z")
        #expect(task.permalinkUrl?.hasPrefix("https://app.asana.com/") == true)
        #expect(task.projects?.map(\.name) == ["Marketing", "Launch"])
        #expect(task.isActive)
    }

    @Test("A compact task with nothing optional still decodes")
    func minimalTask() throws {
        let task = try decodeTask(#"{"gid": "1", "resource_type": "task", "name": "Bare"}"#)
        #expect(task.dueOn == nil && task.dueAt == nil && task.projects == nil)
        #expect(task.isActive)
    }

    @Test("A completed task is not active, whatever the filter promised")
    func completedIsInactive() throws {
        let task = try decodeTask(#"{"gid": "1", "name": "Done", "completed": true}"#)
        #expect(!task.isActive)
    }

    /// `next_page` is `null` on the last page and carries an offset otherwise.
    @Test("A page carries its offset, and null means the end")
    func pagination() throws {
        let more = try JSONDecoder().decode(
            AsanaAPI.Envelope<AsanaAPI.TaskEntry>.self,
            from: Data(#"{"data": [], "next_page": {"offset": "eyJ0eXAi", "path": "/tasks?offset=eyJ0eXAi", "uri": "https://app.asana.com/api/1.0/tasks?offset=eyJ0eXAi"}}"#.utf8))
        #expect(more.nextPage?.offset == "eyJ0eXAi")
        let last = try JSONDecoder().decode(
            AsanaAPI.Envelope<AsanaAPI.TaskEntry>.self,
            from: Data(#"{"data": [{"gid": "1", "name": "x"}], "next_page": null}"#.utf8))
        #expect(last.nextPage == nil)
        #expect(last.data.count == 1)
    }

    @Test("Archived projects are not offered or matched")
    func archivedProjects() {
        let projects = [
            AsanaAPI.Project(gid: "1", name: "Marketing", archived: false),
            AsanaAPI.Project(gid: "2", name: "Old Site", archived: true),
            AsanaAPI.Project(gid: "3", name: "Launch", archived: nil),
        ]
        let resolved = AsanaConnector.resolveProjects(
            named: ["marketing", "Old Site", "LAUNCH"], in: projects)
        #expect(resolved.map(\.gid) == ["1", "3"])
    }
}

@Suite("Asana dates and mapping")
struct AsanaMappingTests {

    @Test("due_at wins and is timed; due_on alone is all-day at local midnight")
    func dueShapes() throws {
        let timed = try #require(
            AsanaAPI.parseDue(dueOn: "2026-09-05", dueAt: "2026-09-05T15:00:00.000Z"))
        #expect(!timed.isAllDay)
        #expect(timed.date == ISO8601Timestamp.date(from: "2026-09-05T15:00:00.000Z"))

        let allDay = try #require(AsanaAPI.parseDue(dueOn: "2026-09-05", dueAt: nil))
        #expect(allDay.isAllDay)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: allDay.date)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 5 && parts.hour == 0)

        #expect(AsanaAPI.parseDue(dueOn: nil, dueAt: nil) == nil)
        #expect(AsanaAPI.parseDue(dueOn: "", dueAt: "") == nil)
    }

    @Test("A wire task becomes a TodoTask with no priority and no recurrence")
    func mapsToTodoTask() throws {
        let task = AsanaAPI.task(from: try decodeTask(timedTaskJSON), preferring: [])
        #expect(task.providerID == "1204567890123456")
        #expect(task.title == "Send the launch email")
        #expect(task.notes == "Draft is in the shared doc.")
        #expect(task.listName == "Marketing")
        #expect(task.isAllDay == false)
        #expect(task.priority == .none)
        #expect(task.isRecurring == false)
        #expect(task.modifiedAt == ISO8601Timestamp.date(from: "2026-09-03T11:30:00.456Z"))
        #expect(task.deepLink == "https://app.asana.com/0/1201/1204567890123456")
    }

    /// A task in several projects is labelled with the one the user chose,
    /// so `TodoScope.accepts` sees the same name whichever request found it.
    @Test("The chosen project names the row when a task is in several")
    func listNamePrefersChosenProject() throws {
        let wire = try decodeTask(timedTaskJSON)
        #expect(AsanaAPI.listName(for: wire.projects, preferring: ["launch"]) == "Launch")
        #expect(AsanaAPI.listName(for: wire.projects, preferring: ["Nope"]) == "Marketing")
        #expect(AsanaAPI.listName(for: [], preferring: ["Launch"]) == nil)
        #expect(AsanaAPI.listName(for: nil, preferring: []) == nil)
    }

    /// No recurrence means the external id is the bare gid — no occurrence
    /// suffix — and Asana's gid is what `C` and ⌘Z act on.
    @Test("The queue id is the bare gid, and overdue is the only high signal")
    func remoteItemIdentity() throws {
        let now = try #require(ISO8601Timestamp.date(from: "2026-09-10T12:00:00Z"))
        let item = TodoItemMapper.remoteItem(
            from: AsanaAPI.task(from: try decodeTask(timedTaskJSON), preferring: []),
            now: now)
        #expect(item.externalID == "1204567890123456")
        #expect(!item.externalID.contains(TodoItemMapper.occurrenceSeparator))
        #expect(item.highSignal, "due 2026-09-05, now 2026-09-10: overdue")
        #expect(TodoPayload.providerID(externalID: item.externalID, payload: item.payload)
            == "1204567890123456")

        let fresh = try decodeTask(#"{"gid": "2", "name": "Later", "due_on": "2026-09-20"}"#)
        let calm = TodoItemMapper.remoteItem(
            from: AsanaAPI.task(from: fresh, preferring: []), now: now)
        #expect(!calm.highSignal, "no priority field, so nothing else can raise it")
    }
}

@Suite("Asana URLs and bodies")
struct AsanaRequestTests {

    /// The spec allows `assignee`+`workspace` *or* `project`, never both.
    @Test("My-tasks asks by assignee and workspace; a project asks alone")
    func filterShapes() throws {
        let mine = try #require(AsanaAPI.myTasksURL(workspace: "W1", offset: nil))
        let mineQuery = try #require(URLComponents(url: mine, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String, in items: [URLQueryItem]) -> String? {
            items.first { $0.name == name }?.value
        }
        #expect(value("assignee", in: mineQuery) == "me")
        #expect(value("workspace", in: mineQuery) == "W1")
        #expect(value("completed_since", in: mineQuery) == "now")
        #expect(value("limit", in: mineQuery) == "100")
        #expect(value("opt_fields", in: mineQuery)?.contains("due_at") == true)
        #expect(value("offset", in: mineQuery) == nil)

        let project = try #require(AsanaAPI.projectTasksURL(project: "P9", offset: "tok"))
        let projectQuery = try #require(URLComponents(url: project, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(value("project", in: projectQuery) == "P9")
        #expect(value("assignee", in: projectQuery) == nil)
        #expect(value("workspace", in: projectQuery) == nil)
        #expect(value("offset", in: projectQuery) == "tok")
    }

    @Test("Update URL escapes the gid, and the body is Asana's envelope")
    func updateRequest() {
        #expect(AsanaAPI.taskURL(gid: "123")?.absoluteString == "https://app.asana.com/api/1.0/tasks/123")
        #expect(AsanaAPI.taskURL(gid: "a b/c")?.absoluteString == "https://app.asana.com/api/1.0/tasks/a%20b%2Fc")
        #expect(AsanaAPI.taskURL(gid: "") == nil)
        #expect(String(decoding: AsanaAPI.completionBody(completed: true), as: UTF8.self)
            == #"{"data":{"completed":true}}"#)
        #expect(String(decoding: AsanaAPI.completionBody(completed: false), as: UTF8.self)
            == #"{"data":{"completed":false}}"#)
    }

    @Test("Projects are listed live only, per workspace")
    func projectsURL() throws {
        let url = try #require(AsanaAPI.projectsURL(workspace: "W1", offset: nil))
        #expect(url.query()?.contains("archived=false") == true)
        #expect(url.query()?.contains("workspace=W1") == true)
    }
}

@Suite("Asana failures (rule 5)")
struct AsanaFailureTests {

    /// The body Asana returned on 2026-09-04 to a request with no token, and
    /// to one with a junk token — byte for byte the same.
    private let unauthorized = Data(
        #"{"errors":[{"message":"Not Authorized","help":"For more information on API status codes and how to handle them, read the docs on errors: https://developers.asana.com/docs/errors"}]}"#.utf8)

    @Test("The message is read out of Asana's JSON envelope")
    func messageExtraction() {
        #expect(AsanaAPI.message(in: unauthorized) == "Not Authorized")
        #expect(AsanaAPI.message(in: Data("plain text".utf8)) == nil)
        #expect(AsanaAPI.message(in: Data(#"{"errors":[]}"#.utf8)) == nil)
        #expect(AsanaAPI.message(in: Data()) == nil)
    }

    @Test("A 401 names the console and does not pretend to know which token problem")
    func unauthorizedWording() {
        let text = AsanaAPI.problem(forHTTPStatus: 401, body: unauthorized, retryAfter: nil)
        #expect(text.contains("developer console"))
        #expect(text.contains("missing, mistyped or revoked"))
        #expect(text.contains("Not Authorized"))
        // The envelope itself must not be pasted in.
        #expect(!text.contains("{\"errors\""))
    }

    @Test("Each status says what to do, and Retry-After is passed through")
    func statusWording() {
        #expect(AsanaAPI.problem(forHTTPStatus: 403, body: Data(), retryAfter: nil).contains("different account"))
        #expect(AsanaAPI.problem(forHTTPStatus: 404, body: Data(), retryAfter: nil).contains("deleted"))
        #expect(AsanaAPI.problem(forHTTPStatus: 429, body: Data(), retryAfter: "30").contains("30s"))
        #expect(AsanaAPI.problem(forHTTPStatus: 503, body: Data(), retryAfter: nil).contains("503"))
        #expect(AsanaAPI.problem(forHTTPStatus: 418, body: Data(), retryAfter: nil).contains("418"))
    }

    @Test("Missing chosen projects are named, all of them")
    func missingProjects() {
        let text = AsanaConnector.missingProjectsMessage(["Marketing", "Launch"])
        #expect(text.contains("“Marketing”") && text.contains("“Launch”"))
        #expect(text.contains("Settings › Sources"))
    }
}

@Suite("Asana registration")
struct AsanaRegistrationTests {

    @Test("Asana is a to-do source with the same four fields as Todoist")
    func catalogEntry() throws {
        let asana = try #require(ConnectorCatalog.descriptor(for: "asana"))
        #expect(asana.fields.map(\.key) == ["token", "dueToday", "projects", "projectsIncludeUndated"])
        #expect(asana.fields.first { $0.key == "token" }?.isSecret == true)
        #expect(asana.fields.first { $0.key == "dueToday" }?.defaultOn == true)
        #expect(asana.fields.first { $0.key == "projectsIncludeUndated" }?.defaultOn == false)
        #expect(!asana.setupSteps.isEmpty)
        #expect(asana.setupURL.contains("asana.com"))
        #expect(asana.allowsMultiple)
        // A fold hides work, so to-do kinds default the Group checkbox off.
        #expect(asana.grouping?.defaultOn == false)
        #expect(asana.completeVerb.help.contains("Asana"))
    }

    @Test("Each fact appears once on the Asana editor screen")
    func editorCopyDoesNotRepeatItself() throws {
        let asana = try #require(ConnectorCatalog.descriptor(for: "asana"))
        let onScreen = asana.sourceNote + asana.setupSteps.joined() + asana.fields.map(\.help).joined()
        #expect(onScreen.components(separatedBy: "Keychain").count - 1 <= 1)
        #expect(onScreen.components(separatedBy: "developer console").count - 1 <= 2)
        #expect(onScreen.components(separatedBy: "Inbox").count - 1 <= 1)
    }

    @Test("The factory builds an Asana connector with the to-do capability set")
    func factoryWiring() throws {
        let config = SourceConfig(kind: "asana", displayName: "Asana")
        config.settings = [
            "dueToday": "false", "projects": "Marketing, Launch",
            "projectsIncludeUndated": "true",
        ]
        let connector = try #require(ConnectorFactory.make(config: config))
        #expect(connector.sourceKind == "asana")
        // The capability set *is* the dismiss-vs-complete feature.
        #expect(connector.capabilities.contains(.completesTask))
        #expect(!connector.capabilities.contains(.markDone))
        #expect(connector.capabilities.contains(.remoteTruth))
        #expect(connector.capabilities.contains(.providesContext))
    }

    @Test("A source asking for nothing says so instead of looking empty")
    func emptyScopeIsRefused() async throws {
        let config = SourceConfig(kind: "asana", displayName: "Asana")
        config.settings = ["dueToday": "false", "projects": ""]
        let connector = try #require(ConnectorFactory.make(config: config))
        // The guard fires before the token is read, so this runs offline.
        await #expect(throws: (any Error).self) { try await connector.fetch() }
    }
}
