import Foundation

// Pure helpers for the D-expansion "context around this message" view —
// filtering the messages worth showing and slicing a window either side of
// the focus. Split out of SlackConnector.swift so the actor is closer to a
// single concern (the run loop and its caches). Tests import these as
// `SlackConnector.foo` unchanged.

extension SlackConnector {
    /// A message as it comes off `conversations.replies`/`history`, before
    /// names and markup are resolved. Value type so the windowing that picks
    /// "3 before, the mention, 3 after" is testable without a network.
    struct ContextRaw: Sendable, Equatable {
        var ts: String
        var user: String?
        var text: String
        /// The parent's ts when this message lives in a thread. What routes
        /// a reply-mention to its thread rather than the channel around it.
        var threadTS: String?
    }

    /// Messages out of a `conversations.*` response worth showing: joins,
    /// leaves and empty texts are noise, not context.
    nonisolated static func rawMessages(_ json: SlackJSON) -> [ContextRaw] {
        (json.array ?? []).compactMap { message in
            guard let ts = message["ts"].nonEmptyString else { return nil }
            if let subtype = message["subtype"].string,
                subtype == "channel_join" || subtype == "channel_leave" {
                return nil
            }
            guard let text = message["text"].nonEmptyString else { return nil }
            return ContextRaw(
                ts: ts,
                user: message["user"].nonEmptyString
                    ?? message["bot_id"].nonEmptyString,
                text: text,
                threadTS: message["thread_ts"].nonEmptyString)
        }
    }

    /// Sorts ascending, dedups (the thread and history paths can both hold
    /// the focus), and slices `radius` messages either side of the focus.
    /// Nil when the focus isn't in what was fetched — showing a window that
    /// provably doesn't contain the mention would be worse than nothing.
    nonisolated static func window(
        _ messages: [ContextRaw], focusTS: String, radius: Int
    ) -> (messages: [ContextRaw], focusIndex: Int)? {
        var seen = Set<String>()
        let sorted = messages
            .filter { seen.insert($0.ts).inserted }
            .sorted { SlackTS.isNewer($1.ts, than: $0.ts) }
        guard let focus = sorted.firstIndex(where: { $0.ts == focusTS })
        else { return nil }
        let low = max(0, focus - radius)
        let high = min(sorted.count - 1, focus + radius)
        return (Array(sorted[low...high]), focus - low)
    }
}
