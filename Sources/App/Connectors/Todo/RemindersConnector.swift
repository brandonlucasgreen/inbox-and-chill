import EventKit
import Foundation
import OSLog

/// Reads Apple Reminders through EventKit. Covers every account Reminders
/// syncs — iCloud, Exchange, anything in the app — for the same reason
/// `AppleMailConnector` covers Gmail.
///
/// This connector is deliberately thin: EventKit in, `[TodoTask]` out. Every
/// decision about how a task *behaves* in the queue lives in
/// `TodoItemMapper` and `TodoScope`, where it can be tested without a
/// permission dialog. A future Todoist connector replaces this file and
/// nothing else.
///
/// **Why `.completesTask` and not `.markDone`.** Brandon's ask, verbatim:
/// *"Dismissing a reminder should not complete it, but rather strike it from
/// the list."* Declaring `.markDone` is what makes the existing `E` key write
/// through to a service — so not declaring it *is* the feature. `E` marks the
/// row done locally and Reminders never hears about it; `C` completes it for
/// real.
///
/// **Facts measured on real Reminders, 2026-08-26** (`docs/todo-sources-plan.md`):
///
/// 1. `predicateForIncompleteReminders(withDueDateStarting:ending:)` **excludes
///    undated reminders**, so the due-today mode cannot accidentally pull in a
///    wishlist.
/// 2. That predicate's `ending:` bound is **inclusive**, and all-day reminders
///    sit at 00:00 local — so the start of tomorrow lets a reminder due
///    *tomorrow* in. `TodoScope.dueWindowEnd` is one second earlier.
/// 3. Completing a recurring reminder completes **only that occurrence**:
///    EventKit splits off a new completed reminder and rolls the original
///    identifier to the next due date. So `C` on a repeating task is safe.
/// 4. `lastModifiedDate` does **not** move when that roll happens, which is
///    why `TodoItemMapper.externalID` puts the occurrence day in the id.
actor RemindersConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "reminders"
    /// No `.markDone` — see the note above; that omission is the feature.
    /// No `.announcesReturn` either: a task's row returning is routine, and
    /// widening that capability is a decision to take deliberately.
    nonisolated let capabilities: ConnectorCapabilities = [
        .completesTask, .remoteTruth, .providesContext,
    ]
    nonisolated let pollInterval: TimeInterval = 60

    private let scope: TodoScope
    private var snapshotComplete = true
    /// The connector's own store.
    ///
    /// `EKEventStore` is not `Sendable`, so it cannot be shared with the UI's
    /// (`RemindersAccess.store`) — each side keeps one and no EventKit object
    /// ever crosses between them. Only `[TodoTask]` leaves this actor. TCC
    /// consent is per-process, so a grant obtained through the UI's store is
    /// immediately usable here.
    private let store = EKEventStore()

    private static let log = Logger(
        subsystem: "lol.bgreen.inboxandchill", category: "reminders")

    /// Past this many tasks the snapshot is reported incomplete rather than
    /// letting `.remoteTruth` archive the tail — the trap `GitHubConnector`
    /// documents, and a live risk here: measured, one list on this Mac holds
    /// 36 open reminders and the unfiltered total is 135.
    ///
    /// Sorted before slicing so the cap keeps the *most urgent* tasks rather
    /// than whatever order EventKit happened to answer in.
    static let maxTasks = 200

    init(sourceID: String, scope: TodoScope) {
        self.sourceID = sourceID
        self.scope = scope
    }

    struct RemindersError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        var description: String { errorDescription ?? "Reminders connector error" }
    }

    // MARK: Fetch

    func fetch() async throws -> [RemoteItem] {
        guard !scope.isEmpty else {
            throw RemindersError(
                errorDescription:
                    "This Reminders source isn't asking for anything yet. Turn on “Due today or overdue”, or pick at least one list, in Settings › Sources."
            )
        }
        // Never prompts (measured). A dialog raised from a 60s timer is the
        // whole failure `RemindersAccessControl` exists to prevent.
        let outcome = RemindersAuthorization.outcome(for: RemindersAccess.status())
        if let refusal = outcome.fetchRefusal {
            // Throwing rather than returning [] is load-bearing: with
            // `.remoteTruth` an empty snapshot means "the user handled all of
            // these" and would archive every task row.
            throw RemindersError(errorDescription: refusal)
        }

        let tasks = try await load()
        let now = Date.now
        let accepted = tasks.filter { scope.accepts($0, now: now) }
        let ordered = Self.rank(accepted)

        snapshotComplete = ordered.count <= Self.maxTasks
        if !snapshotComplete {
            Self.log.info(
                "Reminders snapshot capped at \(Self.maxTasks) of \(ordered.count); archiving suppressed"
            )
        }
        return ordered.prefix(Self.maxTasks).map {
            TodoItemMapper.remoteItem(from: $0, now: now)
        }
    }

    func snapshotWasComplete() async -> Bool { snapshotComplete }

    /// Most urgent first, so a cap drops the least urgent.
    ///
    /// Overdue before due-today before later before undated, then by due date,
    /// then by title so the order is stable poll to poll. `nil` due dates sort
    /// last rather than comparing as `.distantPast`.
    nonisolated static func rank(_ tasks: [TodoTask]) -> [TodoTask] {
        tasks.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.title < b.title
            }
        }
    }

    // MARK: EventKit

    /// Two predicates, unioned by provider id.
    ///
    /// The due window and the chosen lists are asked separately because
    /// EventKit can answer each narrowly, and a task can satisfy both. The
    /// union is de-duplicated on `calendarItemIdentifier`, *not* on the
    /// mapper's external id — the id carries an occurrence suffix and two
    /// predicates cannot disagree about which occurrence is current.
    private func load() async throws -> [TodoTask] {
        let calendars = store.calendars(for: .reminder)
        var byID: [String: TodoTask] = [:]

        if scope.includesDueWindow {
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: TodoScope.dueWindowEnd(),
                calendars: nil)
            for task in try await tasks(matching: predicate) {
                byID[task.providerID] = task
            }
        }

        let wanted = calendars.filter { scope.includesList($0.title) }
        if !wanted.isEmpty {
            // `ending: nil` is what includes undated tasks — measured. The
            // dated-only default is then enforced by `TodoScope.accepts`,
            // because EventKit has no "dated only" predicate to ask for.
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: wanted)
            for task in try await tasks(matching: predicate) {
                byID[task.providerID] = task
            }
        }

        // A list the user named that no longer exists is a real
        // misconfiguration, and silence would leave them staring at an empty
        // source. Named, not swallowed (rule 5).
        let missing = scope.listNames.filter { name in
            !calendars.contains { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        }
        if !missing.isEmpty, byID.isEmpty {
            throw RemindersError(
                errorDescription:
                    "No list named \(missing.map { "“\($0)”" }.joined(separator: " or ")) in Reminders. Lists are matched by name, so renaming one here breaks the link — pick it again in Settings › Sources."
            )
        }
        return Array(byID.values)
    }

    /// `fetchReminders` is completion-based and has no async form.
    ///
    /// The mapping to `TodoTask` happens **inside** the callback on purpose.
    /// `EKReminder` is not `Sendable`, so resuming the continuation with one
    /// would be sending a non-Sendable reference across isolation domains —
    /// the compiler rejects it, and rightly: EventKit objects belong to the
    /// store that produced them. Only the value type leaves.
    private func tasks(matching predicate: NSPredicate) async throws -> [TodoTask] {
        try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(
                    returning: (reminders ?? []).map(Self.task(from:)))
            }
        }
    }

    /// EventKit → the provider-agnostic type. The one place that knows
    /// `EKReminder` exists.
    ///
    /// `dueDateComponents` rather than a `Date` is EventKit's own shape, and
    /// the absence of an `hour` component is how an all-day task announces
    /// itself — measured, 5 of 8 due-today reminders here are all-day.
    nonisolated static func task(from reminder: EKReminder) -> TodoTask {
        let components = reminder.dueDateComponents
        let due = components.flatMap { Calendar.current.date(from: $0) }
        return TodoTask(
            providerID: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            listName: reminder.calendar?.title,
            due: due,
            isAllDay: components?.hour == nil,
            priority: TodoPriority.fromEventKit(reminder.priority),
            isRecurring: reminder.hasRecurrenceRules,
            createdAt: reminder.creationDate,
            modifiedAt: reminder.lastModifiedDate,
            deepLink: deepLink(for: reminder.calendarItemIdentifier))
    }

    /// Reminders.app's own URL scheme.
    ///
    /// Launch Services resolves `x-apple-reminderkit://` to Reminders.app
    /// (measured); whether this exact path opens the right reminder is
    /// **not** verified, so `AppState.openable` gates the scheme to this
    /// source and a miss is a no-op rather than a wrong app opening.
    nonisolated static func deepLink(for identifier: String) -> String {
        "x-apple-reminderkit://REMCDReminder/\(identifier)"
    }

    // MARK: Write-through

    /// Completes the task in Reminders.
    ///
    /// Safe on a repeating reminder: measured 2026-08-26, EventKit completes
    /// only the current occurrence and rolls the original identifier forward
    /// to the next due date. The completed husk it splits off is invisible to
    /// `predicateForIncompleteReminders`, so it leaves no ghost row.
    func complete(externalID: String, payload: Data?) async throws {
        try await setCompleted(true, externalID: externalID, payload: payload)
    }

    /// Un-completes it again, for ⌘Z.
    ///
    /// Not optional polish: without it, undo would restore the queue row while
    /// leaving the task ticked off in Reminders — an undo that silently only
    /// half works.
    func uncomplete(externalID: String, payload: Data?) async throws {
        try await setCompleted(false, externalID: externalID, payload: payload)
    }

    private func setCompleted(
        _ completed: Bool, externalID: String, payload: Data?
    ) async throws {
        guard RemindersAuthorization.outcome(for: RemindersAccess.status()).allowsFetch
        else {
            throw RemindersError(
                errorDescription: RemindersAuthorization.deniedMessage)
        }
        // The queue's id carries the occurrence day for a recurring task, so
        // it is not the id EventKit knows.
        let providerID = TodoPayload.providerID(
            externalID: externalID, payload: payload)
        guard let reminder = store.calendarItem(withIdentifier: providerID)
            as? EKReminder
        else {
            throw RemindersError(
                errorDescription:
                    "That reminder is no longer in Reminders — it was probably deleted there. The row has been \(completed ? "completed" : "restored") here anyway."
            )
        }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersError(
                errorDescription:
                    "Reminders refused to \(completed ? "complete" : "reopen") “\(reminder.title ?? "that reminder")”: \(error.localizedDescription)"
            )
        }
    }

    // MARK: Context (D)

    /// The chips an expanded row shows.
    ///
    /// This exists *because* of the `occurredAt` decision: the queue's Age
    /// column reflects when the task last changed, not when it is due, so the
    /// due date has to be legible somewhere and this is that somewhere.
    func context(externalID: String, payload: Data?) async throws -> ItemContext? {
        guard let decoded = TodoPayload.decode(payload) else { return nil }
        return Self.context(from: decoded, now: .now)
    }

    /// Pure, so the chips are testable without EventKit.
    ///
    /// Built lazily rather than stored in `payload` like Linear's, because
    /// `payload` already carries `TodoPayload` for the write-through and
    /// because "Overdue by 3 days" goes stale sitting in a database.
    nonisolated static func context(from payload: TodoPayload, now: Date)
        -> ItemContext?
    {
        let task = TodoTask(
            providerID: payload.providerID, title: "", listName: payload.listName,
            due: payload.due, isAllDay: payload.isAllDay,
            priority: payload.priority, isRecurring: payload.isRecurring)
        let overdue = payload.due.map {
            TodoItemMapper.isOverdue(due: $0, isAllDay: payload.isAllDay, now: now)
        } ?? false

        var chips: [ItemContext.Chip] = [
            .init(
                systemImage: overdue ? "exclamationmark.circle" : "calendar",
                text: TodoItemMapper.dueDescription(for: task, now: now),
                tint: overdue ? .red : .neutral)
        ]
        if let list = payload.listName, !list.isEmpty {
            chips.append(.init(systemImage: "list.bullet", text: list))
        }
        if payload.isRecurring {
            chips.append(.init(systemImage: "repeat", text: "Repeats"))
        }
        switch payload.priority {
        case .high:
            chips.append(
                .init(systemImage: "flag.fill", text: "High priority", tint: .orange))
        case .medium:
            chips.append(.init(systemImage: "flag", text: "Medium priority"))
        case .low:
            chips.append(.init(systemImage: "flag", text: "Low priority"))
        case .none:
            break
        }
        return ItemContext(chips: chips)
    }
}
