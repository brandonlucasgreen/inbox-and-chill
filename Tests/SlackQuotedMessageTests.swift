import Foundation
import Testing

@testable import InboxAndChill

// MARK: - Quoting DMs (Sources/App/Connectors/Slack/SlackQuotedMessage.swift)

/// A kudos bot's DM quotes a channel message and links nowhere, so the DM
/// row searches for the message it quotes. These cover the pure halves:
/// reading the DM, and choosing among the search matches.
struct SlackQuotedMessageTests {
    /// HeyTaco's shape, ids invented: header line, blank line, `&gt;` quote.
    private let tacoDM = """
        You received *1 taco * from <@U0AAAAAA1|alice> in <#C0BBBBBB2|deploys>.

        &gt;Thanks <@U0CCCCCC3|bob> for jumping on this so fast :pray::skin-tone-2::taco:
        &gt;
        &gt;Rolled back the canary at 19:32Z
        """

    private func json(_ text: String) -> SlackJSON {
        try! JSONDecoder().decode(SlackJSON.self, from: Data(text.utf8))
    }

    private func match(ts: String, channel: String = "C0BBBBBB2", user: String) -> SlackJSON {
        json(
            """
            { "ts": "\(ts)", "user": "\(user)", "channel": { "id": "\(channel)" },
              "permalink": "https://example.slack.com/archives/\(channel)/p\(ts.replacingOccurrences(of: ".", with: ""))" }
            """)
    }

    // MARK: Reading the DM

    @Test func aTacoDMNamesTheChannelTheSenderAndTheWords() throws {
        let quoted = try #require(SlackConnector.quotedMessage(in: tacoDM))
        #expect(quoted.channel == "C0BBBBBB2")
        #expect(quoted.sender == "U0AAAAAA1")
        // Mentions and emoji names are not words the message contains.
        #expect(quoted.words == ["Thanks", "for", "jumping", "this", "fast", "Rolled"])
    }

    @Test func theQueryIsTheWordsUnquoted() throws {
        let quoted = try #require(SlackConnector.quotedMessage(in: tacoDM))
        #expect(SlackConnector.quoteSearchQuery(quoted) == "Thanks for jumping this fast Rolled")
    }

    @Test func unlabelledReferencesAndABareQuoteMarkerStillParse() throws {
        let text = "Taco from <@U0AAAAAA1> in <#C0BBBBBB2>!\n>Shipped the fix"
        let quoted = try #require(SlackConnector.quotedMessage(in: text))
        #expect(quoted.channel == "C0BBBBBB2")
        #expect(quoted.words == ["Shipped", "the", "fix"])
    }

    @Test func anOrdinaryDMIsNotAQuote() {
        #expect(SlackConnector.quotedMessage(in: "lunch at 1?") == nil)
        #expect(SlackConnector.quotedMessage(in: "&gt;quoting you back") == nil)
        #expect(SlackConnector.quotedMessage(in: nil) == nil)
    }

    @Test func aHeaderWithNoQuoteIsNotAQuote() {
        let text = "You received a taco from <@U0AAAAAA1|alice> in <#C0BBBBBB2|deploys>."
        #expect(SlackConnector.quotedMessage(in: text) == nil)
    }

    @Test func aQuoteWithNothingSearchableIsNotAQuote() {
        // Searching for nothing would match anything; better to open the DM.
        let text = "Taco from <@U0AAAAAA1> in <#C0BBBBBB2>\n&gt;<@U0CCCCCC3> :taco: :tada:"
        #expect(SlackConnector.quotedMessage(in: text) == nil)
    }

    @Test func aDMChannelIsNotTakenForTheQuotedChannel() {
        let text = "Taco from <@U0AAAAAA1> in <#D0DDDDDD4>\n&gt;Shipped the fix"
        #expect(SlackConnector.quotedMessage(in: text) == nil)
    }

    @Test func searchWordsAreCapped() {
        let words = SlackConnector.searchWords(
            fromQuote: "one two three four five six seven eight nine ten eleven twelve")
        #expect(words.count == SlackConnector.quoteSearchWordLimit)
        #expect(words.first == "one")
    }

    // MARK: Choosing the match

    @Test func theSendersNewestMessageInTheChannelWins() throws {
        let quoted = try #require(SlackConnector.quotedMessage(in: tacoDM))
        let matches = [
            match(ts: "1795697000.000100", user: "U0AAAAAA1"),
            match(ts: "1795697593.514299", user: "U0AAAAAA1"),
            match(ts: "1795697590.000100", user: "U0EEEEEE5"),
        ]
        let chosen = SlackConnector.originalMatch(
            among: matches, for: quoted, notAfter: "1795697594.093759")
        #expect(chosen?["ts"].string == "1795697593.514299")
    }

    @Test func aMessageAfterTheDMOrInAnotherChannelIsNeverTheOriginal() throws {
        let quoted = try #require(SlackConnector.quotedMessage(in: tacoDM))
        let matches = [
            match(ts: "1795697600.000100", user: "U0AAAAAA1"),
            match(ts: "1795697593.514299", channel: "C0FFFFFF6", user: "U0AAAAAA1"),
        ]
        #expect(
            SlackConnector.originalMatch(
                among: matches, for: quoted, notAfter: "1795697594.093759") == nil)
    }

    @Test func aTacoGivenByReactionFallsBackToTheChannelsNewestMatch() throws {
        // The DM names the reactor, but the quote is someone else's message.
        let quoted = try #require(SlackConnector.quotedMessage(in: tacoDM))
        let matches = [
            match(ts: "1795600000.000100", user: "U0EEEEEE5"),
            match(ts: "1795500000.000100", user: "U0CCCCCC3"),
        ]
        let chosen = SlackConnector.originalMatch(
            among: matches, for: quoted, notAfter: "1795697594.093759")
        #expect(chosen?["ts"].string == "1795600000.000100")
    }
}
