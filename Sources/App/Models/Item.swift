import Foundation
import SwiftData

/// One actionable notification in the triage queue.
///
/// Lifecycle (locked decisions §2.1 of PLAN.md):
/// - Active: `doneAt == nil`, not snoozed. Dies only by explicit done — or by
///   the *source* clearing it (auto-archive with `clearedRemotely`) for
///   remote-truth connectors. Opening an item never completes it.
/// - Snoozed: `snoozedUntil` in the future. Wakes with a banner, always.
/// - Done: `doneAt` set → archived, purged after 90 days.
/// - Pinned: `pinnedAt` set → exempt from auto-clear, done-purge, everything.
@Model
final class Item {
    /// Globally unique across sources: "<sourceKind>:<external id>".
    @Attribute(.unique) var uid: String
    var sourceID: String
    var sourceKind: String
    /// Semantic kind within the source: mention, assigned, review_requested,
    /// dm, emoji_save, follow_up, claude_waiting, custom…
    var kind: String

    var title: String
    var snippet: String?
    var urlString: String?
    var actorName: String?

    /// When the underlying event happened (remote timestamp).
    var occurredAt: Date
    var firstSeenAt: Date
    var updatedAt: Date

    var doneAt: Date?
    /// How the item completed: "user", "remote", "undone" transitions clear it.
    var doneReason: String?
    var snoozedUntil: Date?
    /// Set once a snooze has fired its wake banner so it fires only once.
    var snoozeWakeNotifiedAt: Date?
    var pinnedAt: Date?

    /// Counts toward the high-signal badge mode.
    var highSignal: Bool
    /// Source-specific extras (e.g. Slack channel id, Linear notification id).
    var payload: Data?

    init(
        uid: String, sourceID: String, sourceKind: String, kind: String,
        title: String, snippet: String? = nil, urlString: String? = nil,
        actorName: String? = nil, occurredAt: Date, highSignal: Bool = false,
        payload: Data? = nil
    ) {
        self.uid = uid
        self.sourceID = sourceID
        self.sourceKind = sourceKind
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.urlString = urlString
        self.actorName = actorName
        self.occurredAt = occurredAt
        self.firstSeenAt = .now
        self.updatedAt = .now
        self.highSignal = highSignal
        self.payload = payload
    }
}

extension Item {
    var isDone: Bool { doneAt != nil }
    var isPinned: Bool { pinnedAt != nil }
    var isSnoozed: Bool {
        guard let until = snoozedUntil else { return false }
        return until > .now && doneAt == nil
    }
    var isActive: Bool { doneAt == nil && !isSnoozed }
    var url: URL? { urlString.flatMap(URL.init(string:)) }
}

enum TriagePolicy {
    static let archiveRetention: TimeInterval = 90 * 24 * 3600

    /// Items eligible for purge: done >90 days ago and not pinned.
    static func purgeCutoff(now: Date = .now) -> Date {
        now.addingTimeInterval(-archiveRetention)
    }
}
