import Foundation
import Testing

@testable import InboxAndChill

/// Trello's notification feed as a queue.
///
/// **No live account** (2026-09-04), so as with GitLab these tests are the
/// only verification this connector has. Two things make them worth
/// trusting more than a read-through: the payloads below use Trello's real
/// field names and nesting, and the failure cases use the **actual bodies
/// Trello returned** to a credential-less request on the day this was
/// written — plain text, not JSON.
@Suite("Trello notifications")
struct TrelloTests {
    private func notification(_ raw: String) throws -> TrelloConnector.Notification {
        try JSONDecoder().decode(
            TrelloConnector.Notification.self, from: Data(raw.utf8))
    }

    /// The shape a real `GET /members/me/notifications?memberCreator=true`
    /// returns: the entities live under `data`, and the author under
    /// `memberCreator`.
    private let mention = #"""
        {
          "id": "5dc591ac425f2a223aba0a8e",
          "unread": true,
          "type": "mentionedOnCard",
          "date": "2026-09-04T16:02:52.763Z",
          "memberCreator": { "fullName": "Ada Lovelace", "username": "ada" },
          "data": {
            "text": "@brandon can you look before Friday?",
            "card": { "id": "c1", "name": "Fix the onboarding flow", "shortLink": "aBcD1234" },
            "board": { "id": "b1", "name": "Roadmap", "shortLink": "ZZZ99" }
          }
        }
        """#

    // MARK: Mapping

    @Test("A mention becomes a high-signal row linked to the card")
    func mapsAMention() throws {
        let item = TrelloConnector.item(from: try notification(mention))
        #expect(item.externalID == "5dc591ac425f2a223aba0a8e")
        #expect(item.kind == "mentionedOnCard")
        #expect(item.title == "Mentioned you: Fix the onboarding flow")
        #expect(item.snippet == "@brandon can you look before Friday?")
        #expect(item.url == "https://trello.com/c/aBcD1234")
        #expect(item.actorName == "Ada Lovelace")
        #expect(item.highSignal)
        #expect(item.occurredAt == ISO8601Timestamp.date(from: "2026-09-04T16:02:52.763Z"))
        // Folds by board id, labelled by name.
        #expect(item.groupKey == "b1")
        #expect(item.groupLabel == "Roadmap")
    }

    /// Trello's own spec types `data` as a *string* and puts `card` and
    /// `board` at the top level, which does not match a real response. With
    /// no account to settle it, both shapes decode — this is the spec's one.
    @Test("The spec's top-level card and board shape also decodes")
    func topLevelEntitiesAlsoWork() throws {
        let item = TrelloConnector.item(from: try notification(#"""
            {
              "id": "n2", "type": "cardDueSoon",
              "date": "2026-09-04T09:00:00.000Z",
              "card": { "id": "c9", "name": "Ship the release", "shortLink": "QQ11" },
              "board": { "id": "b9", "name": "Release train" }
            }
            """#))
        #expect(item.title == "Due soon: Ship the release")
        #expect(item.url == "https://trello.com/c/QQ11")
        #expect(item.groupKey == "b9")
        // No comment text, so the board name says where it happened.
        #expect(item.snippet == "Release train")
        #expect(item.highSignal)
    }

    @Test("A board-level notification lands on the board, not nowhere")
    func boardLevelLink() throws {
        let item = TrelloConnector.item(from: try notification(#"""
            {
              "id": "n3", "type": "invitedToBoard",
              "date": "2026-09-04T09:00:00Z",
              "data": { "board": { "id": "b4", "name": "Hiring", "shortLink": "HIR7" } }
            }
            """#))
        #expect(item.title == "Invited you to a board: Hiring")
        #expect(item.url == "https://trello.com/b/HIR7")
    }

    /// A notification with nothing to point at keeps the row and loses only
    /// the link — ⏎ does nothing rather than the poll failing.
    @Test("No card and no board costs the link, not the row")
    func missingEntitiesAreSurvivable() throws {
        let item = TrelloConnector.item(from: try notification(#"""
            {"id": "n4", "type": "changeCard", "date": "2026-09-04T09:00:00Z"}
            """#))
        #expect(item.url == nil)
        #expect(item.groupKey == nil)
        #expect(item.title == "Card changed")
        #expect(!item.highSignal)
    }

    @Test("An unreadable date sorts old rather than immortal")
    func badTimestampSortsOld() throws {
        let item = TrelloConnector.item(from: try notification(#"""
            {"id": "n5", "type": "commentCard", "date": "yesterday"}
            """#))
        #expect(item.occurredAt == .distantPast)
    }

    // MARK: Signal

    /// `commentCard` is out on purpose — the same line `GitHubConnector`
    /// draws by excluding its `comment` reason. `cardDueSoon` is in, because
    /// Trello only sends it for a card you are on.
    @Test("Mentions and assignments badge; comments and card edits do not")
    func signalSplit() {
        for type in ["mentionedOnCard", "addedToCard", "addedMemberToCard",
                     "addedToBoard", "invitedToBoard", "makeAdminOfBoard",
                     "cardDueSoon"] {
            #expect(TrelloConnector.isHighSignal(type: type), "\(type)")
        }
        for type in ["commentCard", "changeCard", "createdCard", "closeBoard",
                     "updateCheckItemStateOnCard", "removedFromCard"] {
            #expect(!TrelloConnector.isHighSignal(type: type), "\(type)")
        }
    }

    @Test("Types read as sentences, including one Trello has not invented")
    func humanizedTypes() {
        #expect(TrelloConnector.humanize(type: "mentionedOnCard") == "Mentioned you")
        #expect(TrelloConnector.humanize(type: "cardDueSoon") == "Due soon")
        #expect(TrelloConnector.humanize(type: "makeAdminOfBoard") == "Made you a board admin")
        // Unknown types split on their camel humps rather than showing raw.
        #expect(TrelloConnector.humanize(type: "addedLabelToCard") == "Added label to card")
        #expect(TrelloConnector.splitCamelCase("changeCard") == "Change card")
    }

    // MARK: Failures (rule 5)

    /// These two bodies are what Trello actually returned on 2026-09-04 to a
    /// request with a junk key and to one with no credentials. They are
    /// **plain text**, so a JSON decoder would have thrown here instead.
    @Test("Trello's plain-text errors name which of the two values is wrong")
    func plainTextErrorsAreAttributed() {
        let badKey = TrelloConnector.explain(
            status: 401, body: Data("invalid key".utf8), writing: false)
        #expect(badKey.contains("API key"))
        #expect(!badKey.contains("token below"))

        let badToken = TrelloConnector.explain(
            status: 400, body: Data("invalid token".utf8), writing: false)
        #expect(badToken.contains("token"))
        #expect(badToken.contains("Token link"))
    }

    @Test("The operation is named, and an empty body says so")
    func failuresNameTheOperation() {
        #expect(
            TrelloConnector.explain(status: 500, body: Data(), writing: true)
                .contains("marking a notification read"))
        #expect(
            TrelloConnector.explain(status: 429, body: Data(), writing: false)
                .contains("rate-limiting"))
        #expect(
            TrelloConnector.explain(status: 401, body: Data(), writing: false)
                .contains("no explanation"))
        #expect(
            TrelloConnector.explain(
                status: 418, body: Data("short and stout".utf8), writing: false)
                .contains("short and stout"))
    }

    /// The credentials ride in the query string, and this sentence is written
    /// to `ProblemLog` on disk. It must never carry a URL.
    @Test("No failure message can leak the key or token")
    func messagesCarryNoCredentials() {
        let statuses = [400, 401, 404, 429, 500, 418]
        for status in statuses {
            for body in ["invalid key", "invalid token", "", "boom"] {
                let text = TrelloConnector.explain(
                    status: status, body: Data(body.utf8), writing: false)
                #expect(!text.contains("api.trello.com"))
                #expect(!text.contains("key="))
                #expect(!text.contains("token="))
            }
        }
    }

    // MARK: Registration

    @Test("Trello is registered, folds by board, and keeps the key unsecret")
    func catalogEntry() throws {
        let trello = try #require(ConnectorCatalog.descriptor(for: "trello"))
        // Trello's own docs call the key public and the token secret.
        #expect(trello.fields.contains { $0.key == "apiKey" && !$0.isSecret })
        #expect(trello.fields.contains { $0.key == "token" && $0.isSecret })
        #expect(!trello.setupSteps.isEmpty)
        #expect(trello.setupURL.contains("trello.com"))
        #expect(trello.grouping?.defaultOn == true)
        let connector = TrelloConnector(sourceID: "t", apiKey: "k")
        #expect(connector.capabilities.contains(.markDone))
        #expect(connector.capabilities.contains(.remoteTruth))
        #expect(!connector.capabilities.contains(.completesTask))
    }

    @Test("Each fact appears once on the Trello editor screen")
    func editorCopyDoesNotRepeatItself() throws {
        let trello = try #require(ConnectorCatalog.descriptor(for: "trello"))
        let onScreen =
            trello.authNote + trello.setupSteps.joined()
            + trello.fields.map(\.help).joined()
        #expect(onScreen.components(separatedBy: "Keychain").count - 1 <= 1)
        #expect(onScreen.components(separatedBy: "Power-Up").count - 1 <= 2)
    }
}
