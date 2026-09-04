import Foundation
import Testing

@testable import InboxAndChill

/// GitLab's To-Do list as a queue.
///
/// **These tests are the only verification this connector has.** Brandon has
/// no GitLab account (2026-09-04), so nothing here has been fed to the real
/// service — which this repo's rule 4 says makes it unverified however
/// carefully written. The fixtures are therefore taken *verbatim* from the
/// payload GitLab's own documentation publishes, field names and nesting
/// included, and the failure paths are pinned as hard as the mappings.
@Suite("GitLab to-dos")
struct GitLabTests {

    /// The example response from GitLab's `/todos` docs, trimmed to the keys
    /// the connector reads but with the real shapes kept — nested `project`,
    /// `author` and `target`, and `id` as a number rather than a string.
    private func todo(_ raw: String) throws -> GitLabConnector.Todo {
        try JSONDecoder().decode(
            GitLabConnector.Todo.self, from: Data(raw.utf8))
    }

    private let mergeRequestTodo = #"""
        {
          "id": 102,
          "project": {
            "id": 2,
            "name": "Gitlab Ce",
            "name_with_namespace": "Gitlab Org / Gitlab Ce",
            "path": "gitlab-foss",
            "path_with_namespace": "gitlab-org/gitlab-foss"
          },
          "author": { "name": "Maxie Medhurst", "username": "craig_rutherford", "id": 12 },
          "action_name": "assigned",
          "target_type": "MergeRequest",
          "target": {
            "id": 34,
            "iid": 7,
            "title": "Fix the upload retry",
            "state": "opened"
          },
          "target_url": "https://gitlab.example.com/gitlab-org/gitlab-foss/-/merge_requests/7",
          "body": "Fix the upload retry",
          "state": "pending",
          "created_at": "2016-06-17T07:52:35.225Z",
          "updated_at": "2016-06-17T07:52:35.225Z"
        }
        """#

    // MARK: Mapping

    @Test("A to-do becomes a row with the reference leading the title")
    func mapsTheDocumentedPayload() throws {
        let item = GitLabConnector.item(from: try todo(mergeRequestTodo))
        #expect(item.externalID == "102")
        #expect(item.kind == "assigned")
        #expect(item.title == "Assigned: !7 · Fix the upload retry")
        #expect(item.url?.contains("/merge_requests/7") == true)
        #expect(item.actorName == "Maxie Medhurst")
        #expect(item.highSignal)
        // Fractional seconds, and never `.now`.
        #expect(item.occurredAt == ISO8601Timestamp.date(from: "2016-06-17T07:52:35.225Z"))
        // Folds by project, exactly as GitHub folds by repo.
        #expect(item.groupKey == "gitlab-org/gitlab-foss")
        #expect(item.groupLabel == "Gitlab Org / Gitlab Ce")
    }

    /// The body is the comment for a mention, and that is what `D` reveals.
    /// When it merely repeats the title it would be a wasted expansion, so
    /// the project path goes there instead — what GitHub's rows carry.
    @Test("The body becomes the snippet only when it says something new")
    func snippetPrefersTheComment() throws {
        let repeated = GitLabConnector.item(from: try todo(mergeRequestTodo))
        #expect(repeated.snippet == "gitlab-org/gitlab-foss")

        let mention = try todo(#"""
            {
              "id": 7, "action_name": "mentioned", "target_type": "Issue",
              "created_at": "2026-09-04T10:00:00.000Z",
              "project": { "path_with_namespace": "acme/api" },
              "target": { "iid": 41, "title": "Rate limit the webhook" },
              "body": "@brandon can you take this before the release?"
            }
            """#)
        let item = GitLabConnector.item(from: mention)
        #expect(item.title == "Mentioned: #41 · Rate limit the webhook")
        #expect(item.snippet == "@brandon can you take this before the release?")
    }

    @Test("GitLab's own sigils, and nothing invented for the rest")
    func references() {
        #expect(GitLabConnector.reference(targetType: "MergeRequest", iid: 7) == "!7")
        #expect(GitLabConnector.reference(targetType: "Issue", iid: 34) == "#34")
        #expect(GitLabConnector.reference(targetType: "Epic", iid: 2) == "&2")
        #expect(GitLabConnector.reference(targetType: "Commit", iid: 9) == nil)
        #expect(GitLabConnector.reference(targetType: "Issue", iid: nil) == nil)
    }

    /// A `Commit` to-do's target id is a SHA string where an issue's is a
    /// number. Decoding that field at all would throw on one of the two and
    /// take the whole poll down, so the type does not have it.
    @Test("A commit to-do decodes, SHA id and all")
    func commitTargetDoesNotBreakDecoding() throws {
        let item = GitLabConnector.item(from: try todo(#"""
            {
              "id": 88, "action_name": "marked", "target_type": "Commit",
              "created_at": "2026-09-04T10:00:00Z",
              "project": { "path_with_namespace": "acme/api" },
              "target": { "id": "a1b2c3d4e5f6", "title": "Bump the client" },
              "target_url": "https://gitlab.com/acme/api/-/commit/a1b2c3"
            }
            """#))
        #expect(item.title == "You marked this: Bump the client")
        #expect(!item.highSignal)
    }

    /// Group-level to-dos arrive without a project; a row with no key must
    /// not fold, and must not crash.
    @Test("A to-do with no project has no fold key")
    func groupLevelTodoHasNoProject() throws {
        let item = GitLabConnector.item(from: try todo(#"""
            {
              "id": 5, "action_name": "member_access_requested",
              "target_type": "Namespace",
              "created_at": "2026-09-04T10:00:00Z",
              "target": { "name": "acme-org" }
            }
            """#))
        #expect(item.groupKey == nil)
        #expect(item.title == "Access requested: acme-org")
        #expect(item.snippet == nil)
    }

    /// An unparseable date must sort old, never new: `.now` beats every
    /// `doneAt`, so `resurrectIfNeeded` would revive the row every poll and
    /// it could never be dismissed.
    @Test("An unreadable timestamp sorts old rather than immortal")
    func badTimestampSortsOld() throws {
        let item = GitLabConnector.item(from: try todo(#"""
            {"id": 1, "action_name": "assigned", "created_at": "last tuesday"}
            """#))
        #expect(item.occurredAt == .distantPast)
    }

    // MARK: Signal

    /// A machine complaining about your own branch is not a person waiting
    /// on you — the line `GitHubConnector` draws by excluding `ci_activity`.
    @Test("People are high-signal; pipelines and your own marks are not")
    func signalSplit() {
        for action in ["assigned", "mentioned", "directly_addressed",
                       "approval_required", "review_requested",
                       "member_access_requested"] {
            #expect(GitLabConnector.isHighSignal(action: action), "\(action)")
        }
        for action in ["build_failed", "unmergeable", "merge_train_removed",
                       "marked"] {
            #expect(!GitLabConnector.isHighSignal(action: action), "\(action)")
        }
    }

    @Test("Every documented action reads as a sentence, and so does a new one")
    func humanizedActions() {
        #expect(GitLabConnector.humanize(action: "build_failed") == "Pipeline failed")
        #expect(GitLabConnector.humanize(action: "approval_required") == "Approval needed")
        #expect(GitLabConnector.humanize(action: "directly_addressed") == "Addressed directly")
        // An action GitLab has not invented yet must not render as a slug.
        #expect(GitLabConnector.humanize(action: "some_new_thing") == "Some new thing")
    }

    // MARK: Host

    @Test("Blank means gitlab.com; a self-managed URL is kept")
    func hostResolution() {
        #expect(
            GitLabConnector.accept(host: "").url?.absoluteString
                == GitLabConnector.defaultHost)
        #expect(
            GitLabConnector.accept(host: "  https://git.acme.dev  ").url?
                .absoluteString == "https://git.acme.dev")
        // Refused by name rather than read off disk on every poll — the
        // `jsonPoller` finding, applied before it can bite here.
        #expect(GitLabConnector.accept(host: "file:///etc/passwd").rejectedScheme == "file")
        #expect(GitLabConnector.accept(host: "not a url").url == nil)
    }

    // MARK: Failures (rule 5)

    /// Verified live on 2026-09-04: gitlab.com answers 401 with
    /// `{"message":"401 Unauthorized"}` for a missing token AND a wrong one,
    /// so the message cannot claim to know which — and because GitLab tokens
    /// expire, it has to raise that possibility itself.
    @Test("The 401 names expiry, not just a wrong token")
    func unauthorizedMentionsExpiry() {
        let text = GitLabConnector.explain(
            status: 401, body: Data(#"{"message":"401 Unauthorized"}"#.utf8),
            writing: false)
        #expect(text.contains("expired"))
        #expect(text.contains("expiry date"))
    }

    /// The scope trap: `read_api` can read this queue but not clear it, so
    /// the failure lands on `E` — the moment it matters most.
    @Test("A 403 while writing names the api scope")
    func forbiddenWhileWritingNamesTheScope() {
        let writing = GitLabConnector.explain(status: 403, body: Data(), writing: true)
        #expect(writing.contains("read_api"))
        #expect(writing.contains("`api`"))
        let reading = GitLabConnector.explain(status: 403, body: Data(), writing: false)
        #expect(reading.contains("scope"))
    }

    @Test("Each failure says which half of the source broke")
    func failuresNameTheOperation() {
        #expect(
            GitLabConnector.explain(status: 404, body: Data(), writing: false)
                .contains("instance URL"))
        #expect(
            GitLabConnector.explain(status: 500, body: Data(), writing: true)
                .contains("marking a to-do done"))
        #expect(
            GitLabConnector.explain(status: 429, body: Data(), writing: false)
                .contains("rate-limiting"))
        // An unknown status still carries the body, so a new GitLab error is
        // readable rather than a bare number.
        #expect(
            GitLabConnector.explain(
                status: 418, body: Data("teapot".utf8), writing: false)
                .contains("teapot"))
    }

    // MARK: Registration

    @Test("GitLab is registered, asks for the api scope, and folds by project")
    func catalogEntry() throws {
        let gitlab = try #require(ConnectorCatalog.descriptor(for: "gitlab"))
        #expect(gitlab.fields.contains { $0.key == "token" && $0.isSecret })
        #expect(gitlab.fields.contains { $0.key == "host" && !$0.isSecret })
        #expect(!gitlab.setupSteps.isEmpty)
        #expect(gitlab.setupURL.contains("gitlab.com"))
        #expect(gitlab.grouping?.defaultOn == true)
        // A token can name any instance, so several sources make sense.
        #expect(gitlab.allowsMultiple)
        let connector = GitLabConnector(sourceID: "g", host: "")
        #expect(connector.capabilities.contains(.markDone))
        #expect(connector.capabilities.contains(.remoteTruth))
        // It is a notification source, not a to-do: `E` is the only verb.
        #expect(!connector.capabilities.contains(.completesTask))
    }

    @Test("Each fact appears once on the GitLab editor screen")
    func editorCopyDoesNotRepeatItself() throws {
        let gitlab = try #require(ConnectorCatalog.descriptor(for: "gitlab"))
        let onScreen =
            gitlab.authNote + gitlab.setupSteps.joined()
            + gitlab.fields.map(\.help).joined()
        #expect(onScreen.components(separatedBy: "Keychain").count - 1 <= 1)
        #expect(onScreen.components(separatedBy: "read_api").count - 1 <= 1)
    }
}
