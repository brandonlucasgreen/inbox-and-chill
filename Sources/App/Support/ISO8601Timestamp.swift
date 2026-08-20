import Foundation

/// Both ISO-8601 shapes a remote service may send, in one place.
///
/// `ISO8601DateFormatter`'s option sets are **mutually exclusive**: the
/// whole-second formatter returns nil for `"2026-08-19T12:34:56.789Z"` and
/// the fractional one returns nil for `"2026-08-19T12:34:56Z"`. So every
/// connector that reads a remote timestamp needs both — and by 2026-08-19
/// three of them (Linear, the JSON poller, Sentry) had each grown their own
/// pair, which is two too many for a rule that is this easy to get subtly
/// wrong.
///
/// **Never substitute `.now` when this returns nil.** `RemoteItem.occurredAt`
/// feeds `Store.resurrectIfNeeded`, which revives a done item when
/// `remote.occurredAt > doneAt` — and a fresh `.now` always is, so the item
/// comes back on every poll and cannot be dismissed. Surface the failure
/// (`JSONPollerConnector` throws) or date it `.distantPast`
/// (`SentryConnector`, `AppleMailConnector`): both are recoverable, `.now` is
/// not. That bug shipped once; see PLAN §6.11.
enum ISO8601Timestamp {
    /// Parses either shape. Fractional is tried first because the services
    /// that send fractions send them on every row, so the common case wins
    /// the first branch; correctness does not depend on the order.
    static func date(from string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }

    /// For the few places that have to *send* a timestamp — Linear's remote
    /// snooze. Fractional, which every API here accepts.
    static func string(from date: Date) -> String {
        fractional.string(from: date)
    }

    // ISO8601DateFormatter is documented thread-safe; it just lacks a
    // Sendable annotation.
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
