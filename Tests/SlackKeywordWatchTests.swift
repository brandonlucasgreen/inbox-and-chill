import Foundation
import Testing

@testable import InboxAndChill

// MARK: - Slack keyword watch (Sources/App/Connectors/Slack/SlackConnector.swift)

/// The keyword watch is the only path that can surface a message from a public
/// channel you are not a member of — events are scoped to your memberships.
/// These cover the pure pieces: term parsing, query building, and match
/// mapping.
struct SlackKeywordWatchTests {
    private func match(_ json: String) -> SlackJSON {
        try! JSONDecoder().decode(SlackJSON.self, from: Data(json.utf8))
    }

    private func hit(
        ts: String, channel: String = "C123", channelName: String = "growth",
        user: String = "U999", text: String = "hello @brandon", permalink: String? = nil
    ) -> SlackJSON {
        let link = permalink.map { "\"permalink\": \"\($0)\"," } ?? ""
        return match(
            """
            {
              "ts": "\(ts)",
              "user": "\(user)",
              "username": "cheryl",
              "text": "\(text)",
              \(link)
              "channel": { "id": "\(channel)", "name": "\(channelName)" }
            }
            """)
    }

    private var now: Date { Date(timeIntervalSince1970: 1_760_000_000) }
    private var cutoff: Date { now.addingTimeInterval(-24 * 60 * 60) }
    private var insideWindow: String { String(now.timeIntervalSince1970 - 60) }

    // MARK: Term parsing

    @Test func termsSplitOnCommasAndNewlines() {
        #expect(
            SlackConnector.parseSearchTerms("@brandon, buffer ai\nkid lightbulbs")
                == ["@brandon", "buffer ai", "kid lightbulbs"])
    }

    @Test func blankAndWhitespaceOnlyInputYieldsNoTerms() {
        #expect(SlackConnector.parseSearchTerms("").isEmpty)
        #expect(SlackConnector.parseSearchTerms("  ,  ,\n ").isEmpty)
    }

    @Test func termsAreTrimmedAndCaseInsensitivelyDeduped() {
        #expect(
            SlackConnector.parseSearchTerms("  Buffer , buffer,BUFFER ") == ["Buffer"])
    }

    /// Every term is one API call per poll, so the list is bounded.
    @Test func termCountIsCapped() {
        let many = (1...25).map { "term\($0)" }.joined(separator: ",")
        #expect(SlackConnector.parseSearchTerms(many).count == 10)
    }

    // MARK: Query building

    @Test func multiWordTermsAreQuotedSoTheyStayAPhrase() {
        let query = SlackConnector.searchQuery(term: "launch measurement", after: cutoff)
        #expect(query.hasPrefix("\"launch measurement\" after:"))
    }

    @Test func singleWordTermsAreNotQuoted() {
        #expect(SlackConnector.searchQuery(term: "bgreen", after: cutoff).hasPrefix("bgreen after:"))
    }

    /// Slack's `after:` is date-granular and exclusive, so the query must ask
    /// for a wider window than the real cutoff and let `watchHit` trim it.
    @Test func queryWindowIsWiderThanTheRealCutoff() {
        let query = SlackConnector.searchQuery(term: "x", after: cutoff)
        let stamp = query.split(separator: ":").last.map(String.init) ?? ""
        var components = DateComponents()
        let parts = stamp.split(separator: "-").compactMap { Int($0) }
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        let asked = Calendar(identifier: .gregorian).date(from: components)!
        #expect(asked < cutoff)
    }

    // MARK: Match mapping

    @Test func aMatchBecomesAQueueItemNamingTheTermAndChannel() {
        let item = SlackConnector.watchHit(
            from: hit(ts: insideWindow, permalink: "https://buffer.slack.com/archives/C123/p1"),
            term: "@brandon", selfUserID: "U001", notBefore: cutoff)
        #expect(item?.item.title == "“@brandon” in #growth")
        #expect(item?.item.kind == "keyword_watch")
        #expect(item?.item.url == "https://buffer.slack.com/archives/C123/p1")
        #expect(item?.item.highSignal == true)
        #expect(item?.channel == "C123")
    }

    /// The external id has to round-trip, or pressing `e` can't clear it.
    @Test func theExternalIDIsAWatchRefThatCanBeCompleted() {
        let item = SlackConnector.watchHit(
            from: hit(ts: insideWindow), term: "x", selfUserID: "U001", notBefore: cutoff)
        #expect(item?.item.externalID == "watch-C123-\(insideWindow)")
    }

    @Test func yourOwnMessagesAreNotNews() {
        #expect(
            SlackConnector.watchHit(
                from: hit(ts: insideWindow, user: "U001"), term: "x",
                selfUserID: "U001", notBefore: cutoff) == nil)
    }

    @Test func matchesOlderThanTheWindowAreDropped() {
        let old = String(cutoff.timeIntervalSince1970 - 3600)
        #expect(
            SlackConnector.watchHit(
                from: hit(ts: old), term: "x", selfUserID: "U001", notBefore: cutoff) == nil)
    }

    @Test func aMatchMissingIDsIsSkippedRatherThanGuessedAt() {
        let noChannel = match("{ \"ts\": \"\(insideWindow)\", \"user\": \"U9\" }")
        #expect(
            SlackConnector.watchHit(
                from: noChannel, term: "x", selfUserID: "U001", notBefore: cutoff) == nil)
        let noTS = match("{ \"channel\": { \"id\": \"C1\" } }")
        #expect(
            SlackConnector.watchHit(
                from: noTS, term: "x", selfUserID: "U001", notBefore: cutoff) == nil)
    }

    // MARK: Dismissal is local to I&C

    /// The whole point of a keyword hit: it is I&C's *own* inbox record of
    /// something it found by searching, not a Slack notification. Dismissing
    /// it must clear that record and touch Slack not at all — which also
    /// makes it dismissable in channels you're not a member of, where
    /// `conversations.mark` would fail.
    ///
    /// Proved by giving the connector no credentials: anything that needs the
    /// Slack API throws, so a `markDone` that *succeeds* here cannot have
    /// called out.
    @Test func dismissingAKeywordHitNeverCallsSlack() async throws {
        let connector = SlackConnector(sourceID: "keyword-watch-test-\(UUID().uuidString)")

        await #expect(throws: (any Error).self) {
            try await connector.markDone(externalID: "mention-C123-1760000000.001", payload: nil)
        }
        try await connector.markDone(externalID: "watch-C123-1760000000.001", payload: nil)
    }

    /// A hit in a channel you were never in still has to round-trip through
    /// the id parser, or the dismissal can't find what to clear.
    @Test func aWatchRefSurvivesTheIDRoundTrip() async throws {
        let connector = SlackConnector(sourceID: "keyword-watch-test-\(UUID().uuidString)")
        // Unknown channel/ts: clearing something not held is a no-op, not an
        // error — the user pressing `e` twice must never surface a failure.
        try await connector.markDone(externalID: "watch-CZZZ-9999999999.999", payload: nil)
    }

    // MARK: Failure is visible, not silent

    /// The banners bug was a feature that returned bare on a permission
    /// problem. A missing scope here has to name itself and the fix.
    @Test func aMissingScopeExplainsItselfAndNamesTheFix() {
        let advice = SlackConnector.searchScopeAdvice(code: "missing_scope")
        #expect(advice.contains("search:read"))
        #expect(advice.contains("reinstall"))
        #expect(advice.contains("missing_scope"))
    }

    @Test func anUnrecognisedRejectionStillSaysWhatSlackReturned() {
        #expect(SlackConnector.searchScopeAdvice(code: "weird_new_code").contains("weird_new_code"))
    }

    /// Slack hands back a raw id as the channel "name" for DMs, which would
    /// otherwise render as `“brandon” in #U4NUMLRJQ`.
    @Test func directMessagesAreDescribedRatherThanPrintedAsAnID() {
        let dm = match(
            "{ \"ts\": \"\(insideWindow)\", \"user\": \"U9\", \"channel\": { \"id\": \"D1\", \"name\": \"U4NUMLRJQ\" } }")
        let item = SlackConnector.watchHit(
            from: dm, term: "brandon", selfUserID: "U001", notBefore: cutoff)
        #expect(item?.item.title == "“brandon” in #a direct message")
    }

    @Test func realChannelNamesAreLeftAlone() {
        #expect(!SlackConnector.isRawChannelID("buffer-build-week-2026"))
        #expect(!SlackConnector.isRawChannelID("prod-apps"))
        #expect(SlackConnector.isRawChannelID("U4NUMLRJQ"))
        #expect(SlackConnector.isRawChannelID("D08ABCDEF12"))
    }

    @Test func anUnnamedChannelStillReadsAsProse() {
        let unnamed = match(
            "{ \"ts\": \"\(insideWindow)\", \"user\": \"U9\", \"channel\": { \"id\": \"C1\" } }")
        let item = SlackConnector.watchHit(
            from: unnamed, term: "pricing", selfUserID: "U001", notBefore: cutoff)
        #expect(item?.item.title == "“pricing” in #a channel")
    }
}
