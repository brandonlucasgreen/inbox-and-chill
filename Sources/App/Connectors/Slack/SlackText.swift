import Foundation

// Pure text helpers for Slack items — no actor state, no network. Split out
// of SlackConnector.swift so the connector itself is closer to a single
// concern (the run loop and its caches). The tests import these as
// `SlackConnector.foo` unchanged.

extension SlackConnector {
    /// How much message text a row carries.
    ///
    /// How much of a message is stored. Twice revised, and each revision
    /// tracked what the row could actually show:
    ///
    /// - **100** — one panel line, with nothing behind it.
    /// - **320** — enough to fill the paragraph a selected row opens to,
    ///   because a cap that stops at the visible line makes the expansion
    ///   reveal nothing but whitespace.
    /// - **4,000** — D drops the clamp entirely, so the target is no longer
    ///   "a paragraph" but "the message". At 320 that keypress revealed a
    ///   line and a half and then an ellipsis it could not get past, which
    ///   read as a broken feature rather than as a cap.
    ///
    /// So this is now a *storage* bound rather than a display one, and it is
    /// the only one left: the panel bounds its own layout work with
    /// `ExpandingText.clampedPrefix`, so a long body costs a row nothing
    /// until it is the selected row. 4,000 covers any message Slack's
    /// composer sends inline — a longer paste becomes a file snippet, which
    /// carries no inline text for us to store anyway. (That composer limit
    /// is from Slack's documentation; it has not been probed here.)
    static let snippetLimit = 4_000

    nonisolated static func truncate(_ text: String?, _ limit: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    /// Strips colons and any skin-tone suffix: `:+1::skin-tone-3:` → `+1`.
    nonisolated static func normalizeEmoji(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasPrefix(":") { name.removeFirst() }
        while name.hasSuffix(":") { name.removeLast() }
        if let separator = name.range(of: "::") {
            name = String(name[name.startIndex..<separator.lowerBound])
        }
        return name
    }

    /// The user and channel ids in a message that Slack did *not* label.
    ///
    /// Pure and static so the parsing can be tested directly — it is the
    /// same `<…>` token grammar `renderText` walks, and getting it wrong
    /// means either a missed name or a wasted API call per message.
    nonisolated static func unlabelledReferences(
        in raw: String
    ) -> (users: [String], channels: [String]) {
        var users: [String] = []
        var channels: [String] = []
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "<"),
            let close = rest[open...].firstIndex(of: ">")
        {
            let token = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            // A label after "|" is the name already; nothing to look up.
            guard !token.contains("|"), let kind = token.first else { continue }
            let id = String(token.dropFirst())
            guard !id.isEmpty else { continue }
            switch kind {
            case "@" where !users.contains(id): users.append(id)
            case "#" where !channels.contains(id): channels.append(id)
            default: break
            }
        }
        return (users, channels)
    }
}
