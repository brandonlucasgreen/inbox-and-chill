import Foundation

/// One open task, as any to-do provider describes it.
///
/// The point of this type is that `RemindersConnector` is the only thing in
/// the app that knows what EventKit is, and a future `TodoistConnector` would
/// be the only thing that knows what Todoist's REST API is. Everything that
/// decides how a task *behaves* in the queue — its identity, its timestamp,
/// whether it is high-signal — is in `TodoItemMapper`, operating on this.
///
/// A to-do is not a notification, and three of these fields are why:
/// `due` is usually in the *future*, `isRecurring` means the same task comes
/// back, and `modifiedAt` is the only timestamp that does not move on its own.
/// See `TodoItemMapper` for what each one is load-bearing for.
struct TodoTask: Sendable, Equatable {
    /// The provider's own stable identifier for the task.
    ///
    /// For a recurring task this is stable across occurrences — measured with
    /// EventKit on 2026-08-26 — which is exactly why `TodoItemMapper` cannot
    /// use it as the queue's external id unchanged.
    var providerID: String
    var title: String
    /// The task's own notes. Stored in full, uncapped, because it is what `D`
    /// reveals; see the Slack-saves lesson in CLAUDE.md.
    var notes: String?
    /// The list ("Groceries") or project the task belongs to.
    var listName: String?
    /// When it is due, or `nil` for an undated task.
    var due: Date?
    /// True when the due date carries no time of day.
    ///
    /// Measured: 5 of 8 reminders due today on Brandon's Mac are all-day, so
    /// this is the common case, and the UI must not invent a clock time.
    var isAllDay: Bool = false
    var priority: TodoPriority = .none
    /// True when completing this task produces another occurrence.
    var isRecurring: Bool = false
    var createdAt: Date?
    /// The provider's last-modified stamp.
    ///
    /// Measured **not** to move when a recurring reminder's occurrence rolls
    /// forward, which is the whole reason `TodoItemMapper.externalID` exists.
    var modifiedAt: Date?
    /// A deep link back into the provider, if it has one.
    var deepLink: String?
}

/// Normalised across providers: EventKit uses 1/5/9 with 0 for unset, Todoist
/// uses 1–4 the other way up, and neither maps onto the other by arithmetic.
enum TodoPriority: Int, Sendable, Equatable, Codable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    /// EventKit's `EKReminder.priority`: 0 unset, 1–4 high, 5 medium, 6–9 low.
    /// Spelled out rather than divided, because the bands are not even.
    static func fromEventKit(_ raw: Int) -> TodoPriority {
        switch raw {
        case 1...4: return .high
        case 5: return .medium
        case 6...9: return .low
        default: return .none
        }
    }

    /// Todoist's `priority`: **1 is the default every task has** and 4 is
    /// urgent — the inverse of EventKit, and also the inverse of the labels
    /// Todoist's own UI prints, where `priority: 4` is shown as "P1".
    ///
    /// Mapping 1 to `.none` rather than `.low` is the load-bearing half.
    /// `TodoItemMapper.highSignal` fires on `.high`, and every untouched
    /// Todoist task arrives as 1 — so treating 1 as a real priority would
    /// make "has a priority" true of the entire account and say nothing.
    static func fromTodoist(_ raw: Int) -> TodoPriority {
        switch raw {
        case 4: return .high
        case 3: return .medium
        case 2: return .low
        default: return .none
        }
    }

    /// Back to EventKit's scale, for a write-through that has to preserve it.
    var eventKitValue: Int {
        switch self {
        case .none: return 0
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }
}

/// The bits of a task the app needs *after* the snapshot: to write a
/// completion back, and to draw the context chips on `D`.
///
/// Rides in `RemoteItem.payload` like `SlackConnector`'s channel id. The
/// important field is `providerID`: the queue's external id for a recurring
/// task carries an occurrence suffix, so the id the write-through needs is
/// **not** the id it is handed. Carrying it explicitly means the connector
/// never has to parse its own id format back apart.
struct TodoPayload: Codable, Sendable, Equatable {
    var providerID: String
    var listName: String?
    var due: Date?
    var isAllDay: Bool
    var isRecurring: Bool
    var priority: TodoPriority

    init(from task: TodoTask) {
        self.providerID = task.providerID
        self.listName = task.listName
        self.due = task.due
        self.isAllDay = task.isAllDay
        self.isRecurring = task.isRecurring
        self.priority = task.priority
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data?) -> TodoPayload? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(TodoPayload.self, from: data)
    }

    /// The provider id to act on, given whatever the triage layer handed back.
    ///
    /// Prefers the payload, because that is authoritative. Falls back to
    /// splitting the external id at its occurrence separator so an item whose
    /// payload predates this field — or was dropped — still completes rather
    /// than silently doing nothing (rule 5).
    static func providerID(externalID: String, payload: Data?) -> String {
        if let decoded = decode(payload), !decoded.providerID.isEmpty {
            return decoded.providerID
        }
        return String(
            externalID.prefix(while: { $0 != TodoItemMapper.occurrenceSeparator }))
    }
}
