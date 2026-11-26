import Foundation

// A DM that quotes a channel message, and the message it quotes.
//
// Kudos bots tell you about a message by quoting it in a DM. HeyTaco's
// is the shape this was built against:
//
//     You received *1 taco* from <@U0AAAAAA1|alice> in <#C0BBBBBB2|deploys>.
//
//     &gt;Thanks <@U0CCCCCC3|bob> for jumping on this so fast :pray: …
//
// The DM row links to the DM, which only repeats the quote. The bot gives
// no permalink and its API has no per-message data, so these helpers turn
// the quote into a `search.messages` query and pick the original out of
// the matches. Pure, so the parsing and the choice are testable without a
// workspace.

extension SlackConnector {
    /// What a quoting DM says about the message it quotes.
    struct QuotedMessage: Equatable, Sendable {
        /// The channel the quoted message is in.
        var channel: String
        /// Who the bot says the message came from. For a taco given by
        /// reacting to someone else's message, this is the reactor, not the
        /// author, so it ranks matches rather than filtering them.
        var sender: String
        /// Plain words from the quote, for the search query.
        var words: [String]
    }

    /// Words sent to search. Slack ANDs them, so a few distinctive words
    /// find the message and more only add ways for a reworded quote to miss.
    static let quoteSearchWordLimit = 6

    /// Reads a DM as "a bot quoting a channel message", or returns nil.
    ///
    /// Three things are required, and a DM that has all three is a quote
    /// whoever wrote it: a `from <@U…>` and an `in <#C…>` before the quote,
    /// and a `>` quote with at least one searchable word. Slack sends the
    /// quote marker as `&gt;` in message text; a bare `>` is accepted too.
    nonisolated static func quotedMessage(in text: String?) -> QuotedMessage? {
        guard let text, !text.isEmpty else { return nil }
        var header: [Substring] = []
        var quote: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let body = quoteBody(line) {
                quote.append(body)
            } else if quote.isEmpty {
                header.append(line)
            }
        }
        let intro = header.joined(separator: " ")
        guard let sender = referenceID(in: intro, after: "from <@", prefixes: "UW"),
            let channel = referenceID(in: intro, after: "in <#", prefixes: "CG")
        else { return nil }
        let words = searchWords(fromQuote: quote.joined(separator: " "))
        guard !words.isEmpty else { return nil }
        return QuotedMessage(channel: channel, sender: sender, words: words)
    }

    /// The `search.messages` query for a quote: its words, unquoted.
    ///
    /// Not a quoted phrase, because the quote has mentions and emoji cut
    /// out of it, so its words are no longer adjacent in the original. And
    /// no `in:`/`from:` modifiers: the channel is checked against each
    /// match's id in `originalMatch`, which needs no query syntax to hold.
    nonisolated static func quoteSearchQuery(_ quoted: QuotedMessage) -> String {
        quoted.words.joined(separator: " ")
    }

    /// The match that is the quoted message, or nil.
    ///
    /// Only matches in the quoted channel, posted no later than the DM,
    /// count. Of those, the newest from the named sender wins. When the
    /// sender wrote none of them (a taco given by reaction quotes someone
    /// else's message), the newest in the channel wins instead.
    nonisolated static func originalMatch(
        among matches: [SlackJSON], for quoted: QuotedMessage, notAfter dmTS: String
    ) -> SlackJSON? {
        let candidates = matches.filter { match in
            guard match["channel"]["id"].string == quoted.channel,
                let ts = match["ts"].nonEmptyString
            else { return false }
            return !SlackTS.isNewer(ts, than: dmTS)
        }
        func newest(_ list: [SlackJSON]) -> SlackJSON? {
            list.max { SlackTS.isNewer($1["ts"].string ?? "", than: $0["ts"].string ?? "") }
        }
        return newest(candidates.filter { $0["user"].string == quoted.sender })
            ?? newest(candidates)
    }

    // MARK: - Parsing pieces

    /// The text of a quote line, without its marker.
    private nonisolated static func quoteBody(_ line: Substring) -> Substring? {
        for marker in ["&gt;", ">"] where line.hasPrefix(marker) {
            return line.dropFirst(marker.count)
        }
        return nil
    }

    /// The id in the first `<@U…>`-style reference after `marker`, when it
    /// starts with one of `prefixes` and is shaped like a Slack id.
    private nonisolated static func referenceID(
        in text: String, after marker: String, prefixes: String
    ) -> String? {
        guard let start = text.range(of: marker)?.upperBound else { return nil }
        let id = text[start...].prefix { $0 != "|" && $0 != ">" }
        guard id.count >= 2, let first = id.first, prefixes.contains(first),
            id.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
        else { return nil }
        return String(id)
    }

    /// Searchable words from a quote. Drops `<…>` references and links,
    /// `:emoji:` codes and markup, then keeps words of three or more
    /// letters or digits, up to `quoteSearchWordLimit`.
    nonisolated static func searchWords(fromQuote quote: String) -> [String] {
        var plain = ""
        var rest = Substring(quote)
        while let open = rest.firstIndex(of: "<") {
            plain += rest[..<open]
            guard let close = rest[open...].firstIndex(of: ">") else {
                rest = rest[rest.endIndex...]
                break
            }
            plain += " "
            rest = rest[rest.index(after: close)...]
        }
        plain += rest
        plain = stripEmojiCodes(
            plain.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: " ")
                .replacingOccurrences(of: "&gt;", with: " "))

        var words: [String] = []
        for word in plain.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        where word.count >= 3 {
            words.append(String(word))
            if words.count == quoteSearchWordLimit { break }
        }
        return words
    }

    /// Removes `:name:` emoji codes, including chained skin tones
    /// (`:pray::skin-tone-2:`), so their names don't become search words.
    private nonisolated static func stripEmojiCodes(_ text: String) -> String {
        let nameCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789_+-'")
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == ":" {
                let after = text.index(after: index)
                if let close = text[after...].firstIndex(of: ":"), close > after,
                    text[after..<close].allSatisfy({ nameCharacters.contains($0) })
                {
                    out += " "
                    index = text.index(after: close)
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }
}
