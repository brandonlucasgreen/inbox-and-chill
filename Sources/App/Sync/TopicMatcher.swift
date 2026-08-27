import Foundation

/// What a topic's catch terms are, and whether an item matches one.
///
/// Pure and `nonisolated static` throughout (rule 6): the `Store` is an
/// actor and connectors are actors, so everything worth testing lives here
/// and the tests call it directly with plain strings.
///
/// The token rules come from a measurement rather than from taste — 2,223
/// items read out of the live store on 2026-08-26, written up in
/// `docs/topic-grouping-plan.md`:
///
/// - **An issue key is the identifier that crosses sources.** `EPD-1873`
///   appears in Linear titles, GitHub titles, Mail subjects and Claude Code
///   snippets; 461 distinct keys in the store, 14 of them spanning more than
///   one source kind.
/// - **A bare `#1234` is not, and adding it would be a bug.** It produced a
///   false match on the first pass — `#116` tied a test row to an unrelated
///   Linear row. Only a repo-qualified `owner/repo#123` is admitted.
/// - **Reminders never carry either. 0 of 22.** Which is why matching is a
///   layer on top of hand-picked membership and never a replacement for it.
enum TopicMatcher {

    /// The text of one item, in the three places a term can hide.
    struct Fields: Sendable, Equatable {
        var title: String
        var snippet: String?
        var url: String?

        init(title: String, snippet: String? = nil, url: String? = nil) {
            self.title = title
            self.snippet = snippet
            self.url = url
        }

        var haystack: String {
            [title, snippet ?? "", url ?? ""].joined(separator: " ")
        }
    }

    /// At most this many terms are suggested. A topic with eight rules is one
    /// nobody can predict the behaviour of.
    static let maximumSuggestedTerms = 4

    /// How many links to read out of one item's text. A chatty Slack message
    /// can carry a dozen, and every one of them would be a candidate rule.
    static let maximumLinks = 3

    // MARK: Matching

    /// Whether any term appears in the item's title, snippet or URL.
    ///
    /// Case-insensitive, on word boundaries. The boundary is load-bearing:
    /// without it the term `EPD-187` swallows every `EPD-1873`, and a topic
    /// silently eats a neighbouring issue's notifications.
    nonisolated static func matches(_ terms: [String], _ fields: Fields) -> Bool {
        guard !terms.isEmpty else { return false }
        let haystack = fields.haystack.lowercased()
        return terms.contains { term in
            let term = term.trimmingCharacters(in: .whitespaces).lowercased()
            guard !term.isEmpty else { return false }
            return containsWord(haystack, term)
        }
    }

    /// Substring search that refuses a match glued to a letter or digit.
    ///
    /// Written by hand rather than as a regex because the terms are
    /// user-typed: a term containing `(`, `+` or `?` would either need
    /// escaping at every call site or quietly become a pattern.
    nonisolated static func containsWord(
        _ haystack: String, _ needle: String
    ) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return false
        }
        var searchStart = haystack.startIndex
        while let found = haystack.range(
            of: needle, range: searchStart..<haystack.endIndex)
        {
            let leftOK =
                found.lowerBound == haystack.startIndex
                || !isWordCharacter(
                    haystack[haystack.index(before: found.lowerBound)])
            let rightOK =
                found.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[found.upperBound])
            if leftOK && rightOK { return true }
            guard found.lowerBound < haystack.endIndex else { return false }
            searchStart = haystack.index(after: found.lowerBound)
        }
        return false
    }

    private nonisolated static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: Suggestions

    /// Terms shared by two or more of the selected items, best first.
    ///
    /// "Two or more" is the whole filter. A token that appears in one member
    /// says nothing about what the group is *about*, and offering it as a
    /// rule invites a topic that catches an entire project.
    nonisolated static func suggestedTerms(for items: [Fields]) -> [String] {
        guard items.count > 1 else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for item in items {
            // `tokens` already deduplicates within one item, so a key
            // repeated in both a title and a URL still counts once — which
            // is what makes "shared by two or more *items*" true.
            for token in tokens(in: item) {
                if counts[token] == nil { order.append(token) }
                counts[token, default: 0] += 1
            }
        }
        let shared = order.filter { (counts[$0] ?? 0) > 1 }
        // Issue keys first: measured as the token that actually crosses
        // sources, where a shared URL is usually two rows from one source.
        let keys = shared.filter { isIssueKey($0) }
        let rest = shared.filter { !isIssueKey($0) }
        return Array((keys + rest).prefix(maximumSuggestedTerms))
    }

    /// Every catchable token in one item, deduplicated, in reading order.
    nonisolated static func tokens(in fields: Fields) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ token: String) {
            let key = token.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            found.append(token)
        }
        let text = fields.haystack
        for match in matches(of: Patterns.issueKey, in: text) { add(match) }
        for match in matches(of: Patterns.repoIssue, in: text) { add(match) }
        // Links are read out of the *whole* haystack, not just the `url`
        // field, because the shared-link case is asymmetric by nature: the
        // Linear row carries the issue URL as its link while the Slack
        // message merely mentions it in its text. Only scanning `url` would
        // mean the token is never shared, and the one thing linking those two
        // rows would go unnoticed.
        if let url = fields.url, let normalized = normalizedURL(url) {
            add(normalized)
        }
        for match in matches(of: Patterns.link, in: text).prefix(maximumLinks) {
            if let normalized = normalizedURL(trimmedTrailingPunctuation(match)) {
                add(normalized)
            }
        }
        return found
    }

    nonisolated static func isIssueKey(_ token: String) -> Bool {
        guard let regex = Patterns.issueKey else { return false }
        let range = NSRange(token.startIndex..., in: token)
        guard let match = regex.firstMatch(in: token, range: range) else {
            return false
        }
        return match.range == range
    }

    /// Scheme + host + path, so a link with a tracking query and one without
    /// are the same term.
    nonisolated static func normalizedURL(_ string: String) -> String? {
        guard var components = URLComponents(string: string),
            let host = components.host, !host.isEmpty
        else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.path = path
        // A bare host is not a topic. "github.com" would catch the lot.
        guard path.count > 1 else { return nil }
        return components.string
    }

    /// A first name for a new topic, for the field to be pre-filled with.
    ///
    /// Deliberately modest: the issue key plus the cleanest member title we
    /// can produce, and the user edits it. Guessing harder here means
    /// guessing wrong in a text field they are already looking at.
    nonisolated static func suggestedName(for items: [Fields]) -> String {
        let key = suggestedTerms(for: items).first(where: isIssueKey)
        let body =
            items
            .filter { item in
                guard let key else { return true }
                return item.haystack.contains(key)
            }
            .map { strippedEventPrefix($0.title) }
            .filter { !$0.isEmpty }
            .min { $0.count < $1.count } ?? items.first?.title ?? ""
        let cleaned = clamp(strip(key: key, from: body), to: 68)
        guard let key else { return cleaned }
        return cleaned.isEmpty ? key : "\(key) — \(cleaned)"
    }

    /// Drops the connector's event prefix — "Checks failed: ", "Mentioned: ",
    /// "New comment on " — so the name reads as the thing, not the event.
    nonisolated static func strippedEventPrefix(_ title: String) -> String {
        guard let range = title.range(of: ": ") else { return title }
        let prefix = title[title.startIndex..<range.lowerBound]
        // Only a short, wordy prefix: "feat(core-api)" and "ENG-12" both
        // contain a colon and are part of the name, not a label on it.
        guard prefix.count <= 24,
            prefix.allSatisfy({ $0.isLetter || $0 == " " })
        else { return title }
        return String(title[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func strip(key: String?, from title: String) -> String {
        guard let key else { return title }
        var text = title.replacingOccurrences(of: key, with: "")
        while let last = text.last, last == "/" || last == "-" || last == " " {
            text.removeLast()
        }
        while let first = text.first, first == "/" || first == "-" || first == " " {
            text.removeFirst()
        }
        return text
    }

    private nonisolated static func clamp(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Patterns

    private enum Patterns {
        /// `EPD-1873`, `CORE-7130`. Case-sensitive on the letters on
        /// purpose — lowercasing it turns every `abc-123` URL slug into an
        /// issue key.
        static let issueKey = try? NSRegularExpression(
            pattern: "\\b[A-Z]{2,6}-\\d{1,6}\\b")
        /// `buffer/core#1740`. A bare `#1740` is deliberately absent.
        static let repoIssue = try? NSRegularExpression(
            pattern: "\\b[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#\\d{1,6}\\b")
        /// An http(s) link anywhere in the text. Other schemes are excluded:
        /// `x-apple-reminderkit://` and friends are per-item identifiers, so
        /// they can never be shared and would only ever be noise.
        static let link = try? NSRegularExpression(
            pattern: "https?://[^\\s<>\"\']+")
    }

    /// Trailing `.`, `)` or `>` belong to the sentence, not to the link.
    private nonisolated static func trimmedTrailingPunctuation(
        _ text: String
    ) -> String {
        var text = text
        while let last = text.last,
            ".,;:)]>\u{201D}".contains(last)
        {
            text.removeLast()
        }
        return text
    }

    private nonisolated static func matches(
        of regex: NSRegularExpression?, in text: String
    ) -> [String] {
        guard let regex else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
