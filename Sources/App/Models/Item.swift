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
    ///
    /// A property of the notification's *type* — "someone specifically wants
    /// you" — decided by each connector's own allowlist and fixed for the
    /// item's life. Deliberately NOT a read/unread state; that's `seenAt`.
    var highSignal: Bool
    /// When the item first held the panel's selection.
    ///
    /// Optional so existing rows migrate in as unseen rather than silently
    /// counting as read.
    var seenAt: Date?
    /// When the user explicitly marked the item unread (`U`).
    ///
    /// Focus alone marks a row seen, so without this an explicit "unread"
    /// would survive exactly until you arrowed past the row again — which is
    /// to say, never. While this is set, auto-seen leaves the item alone.
    var unreadHeldAt: Date?
    /// Source-specific extras (e.g. Slack channel id, Linear notification id).
    var payload: Data?
    /// The `Topic` this item belongs to, or nil.
    ///
    /// **Local state, like `pinnedAt`, `seenAt` and `unreadHeldAt` — and so
    /// deliberately absent from `Store.update(_:from:)`.** That method
    /// refreshes nearly every field from the remote on every poll (`kind` was
    /// added to it recently and correctly), so a field that must survive a
    /// poll has to be left out of it by hand. A poll dissolving the topic the
    /// user just built is the regression this comment exists to prevent.
    var topicID: String?
    /// What the source says this item is about — see `RemoteItem.groupKey`.
    ///
    /// **Source state, like `kind` and `title`, and so deliberately
    /// refreshed by `Store.update(_:from:)`** — the opposite rule from
    /// `topicID`, for the opposite reason. A topic is yours and a poll must
    /// not dissolve it; a channel label is the source's, and a poll is how a
    /// renamed channel comes to read correctly. Nothing is written to the
    /// store when rows fold: auto-grouping is computed from these two fields
    /// by `PanelQueue`, so turning it off gives back exactly the queue you had.
    var groupKey: String?
    var groupLabel: String?

    init(
        uid: String, sourceID: String, sourceKind: String, kind: String,
        title: String, snippet: String? = nil, urlString: String? = nil,
        actorName: String? = nil, occurredAt: Date, highSignal: Bool = false,
        payload: Data? = nil, groupKey: String? = nil, groupLabel: String? = nil
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
        self.groupKey = groupKey
        self.groupLabel = groupLabel
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
    /// Whether the user has ever focused this row. Drives the dot.
    var isSeen: Bool { seenAt != nil }
    /// Whether the user has pinned this item to unread by hand.
    var isHeldUnread: Bool { unreadHeldAt != nil }
    var url: URL? { urlString.flatMap(URL.init(string:)) }
}

enum TriagePolicy {
    static let archiveRetention: TimeInterval = 90 * 24 * 3600

    /// Items eligible for purge: done >90 days ago and not pinned.
    static func purgeCutoff(now: Date = .now) -> Date {
        now.addingTimeInterval(-archiveRetention)
    }
}
