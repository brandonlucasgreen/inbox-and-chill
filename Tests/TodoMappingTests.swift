import Foundation
import Testing

@testable import InboxAndChill

// MARK: - Sources/App/Connectors/Todo/
//
// Every test here is a guard on a decision that was arrived at by measuring
// EventKit on 2026-08-26 (see docs/todo-sources-plan.md). The two that matter
// most are `dismissalSticks…` and `recurringOccurrence…`: between them they
// pin the reason a task's identity and timestamp are what they are, and both
// failure modes are silent — a dismissed task that will not stay dismissed,
// and a repeating task that disappears forever.

private let utc = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")!
    return formatter.date(from: iso)!
}

private func task(
    id: String = "TASK-1", title: String = "Water the plants",
    notes: String? = nil, list: String? = "Home", due: Date? = nil,
    allDay: Bool = false, priority: TodoPriority = .none,
    recurring: Bool = false, created: Date? = nil, modified: Date? = nil
) -> TodoTask {
    TodoTask(
        providerID: id, title: title, notes: notes, listName: list, due: due,
        isAllDay: allDay, priority: priority, isRecurring: recurring,
        createdAt: created, modifiedAt: modified)
}

struct TodoFoldKeyTests {
    @Test("A task folds by its list — offered, off by default")
    func listIsTheKey() {
        let item = TodoItemMapper.remoteItem(from: task(list: "Home"), now: .now)
        #expect(item.groupKey == "Home")
        #expect(item.groupLabel == "Home")
        let unlisted = TodoItemMapper.remoteItem(from: task(list: nil), now: .now)
        #expect(unlisted.groupKey == nil)
        let blank = TodoItemMapper.remoteItem(from: task(list: ""), now: .now)
        #expect(blank.groupKey == nil)
    }

    @Test("To-do sources default to grouping off; notification sources on")
    func catalogDefaults() {
        #expect(ConnectorCatalog.descriptor(for: "reminders")?.grouping?.defaultOn == false)
        #expect(ConnectorCatalog.descriptor(for: "todoist")?.grouping?.defaultOn == false)
        #expect(ConnectorCatalog.descriptor(for: "slack")?.grouping?.defaultOn == true)
        #expect(ConnectorCatalog.descriptor(for: "local")?.grouping == nil)
        #expect(ConnectorCatalog.descriptor(for: "jsonPoller")?.grouping == nil)
    }
}

struct TodoIdentityTests {

    /// The bug this whole design turns on. A task's due date is in the future,
    /// and `Store.resurrectIfNeeded` revives a done item whose `occurredAt`
    /// has moved past its `doneAt` — so an `occurredAt` of "when it's due"
    /// un-dismisses the row on the very next poll.
    @Test func occurredAtIsNeverInTheFuture() {
        let now = date("2026-08-26T14:00:00Z")
        let dueLater = task(due: date("2026-08-26T17:00:00Z"))
        #expect(TodoItemMapper.occurredAt(for: dueLater, now: now) <= now)

        // Even with no other timestamp to fall back on.
        #expect(
            TodoItemMapper.occurredAt(
                for: task(due: date("2027-01-01T00:00:00Z")), now: now) == now)
    }

    @Test func occurredAtPrefersModifiedThenCreated() {
        let now = date("2026-08-26T14:00:00Z")
        let modified = date("2026-08-25T09:00:00Z")
        let created = date("2026-05-13T11:00:00Z")

        #expect(
            TodoItemMapper.occurredAt(
                for: task(due: date("2026-08-26T17:00:00Z"), created: created,
                    modified: modified), now: now) == modified)
        #expect(
            TodoItemMapper.occurredAt(
                for: task(created: created), now: now) == created)
    }

    /// A recurring task's next occurrence has to arrive as a *new* item,
    /// because `lastModifiedDate` does not move when the occurrence rolls
    /// (measured). Without this a repeating reminder is completed once and
    /// never seen again.
    @Test func recurringOccurrenceGetsItsOwnIdentity() {
        let today = task(
            due: date("2026-08-26T13:00:00Z"), recurring: true,
            modified: date("2026-08-26T13:46:13Z"))
        // Same providerID, same modifiedAt — only the due date rolled. This is
        // exactly what the spike observed.
        let tomorrow = task(
            due: date("2026-08-27T13:00:00Z"), recurring: true,
            modified: date("2026-08-26T13:46:13Z"))

        let a = TodoItemMapper.externalID(for: today, calendar: utc)
        let b = TodoItemMapper.externalID(for: tomorrow, calendar: utc)
        #expect(a != b, "tomorrow's occurrence must not reuse today's uid")
        #expect(a == "TASK-1#2026-08-26")
        #expect(b == "TASK-1#2026-08-27")
    }

    /// The other half: a one-off task keeps a bare id, so rescheduling it
    /// updates the row in place instead of orphaning it and inserting a
    /// duplicate.
    @Test func nonRecurringTaskKeepsABareIdentity() {
        let before = task(due: date("2026-08-26T13:00:00Z"))
        let after = task(due: date("2026-09-02T13:00:00Z"))
        #expect(TodoItemMapper.externalID(for: before, calendar: utc) == "TASK-1")
        #expect(TodoItemMapper.externalID(for: after, calendar: utc) == "TASK-1")
    }

    /// Measured: an uncompleted recurring reminder does **not** roll forward —
    /// it stays at its due date and goes overdue. So the same task read again
    /// hours later must keep the *same* uid, or a neglected daily task would
    /// churn a new row (and a new archive row) every poll.
    @Test func neglectedRecurringOccurrenceKeepsItsIdentity() {
        let due = date("2026-08-25T13:00:00Z")
        let neglected = task(
            due: due, recurring: true, modified: date("2026-08-24T09:00:00Z"))

        let yesterday = TodoItemMapper.externalID(for: neglected, calendar: utc)
        // A day later, nothing about the task has changed.
        #expect(TodoItemMapper.externalID(for: neglected, calendar: utc) == yesterday)
        #expect(yesterday == "TASK-1#2026-08-25")

        // And it reads as overdue and high-signal rather than disappearing.
        let now = date("2026-08-26T14:00:00Z")
        #expect(
            TodoItemMapper.kind(for: neglected, now: now, calendar: utc)
                == "todo_overdue")
        #expect(TodoItemMapper.highSignal(for: neglected, now: now, calendar: utc))
        // Still not in the future, so dismissing it still sticks.
        #expect(TodoItemMapper.occurredAt(for: neglected, now: now) < now)
    }

    /// A repeating task with no due date has no occurrence to name.
    @Test func recurringWithoutDueDateKeepsABareIdentity() {
        #expect(
            TodoItemMapper.externalID(for: task(recurring: true), calendar: utc)
                == "TASK-1")
    }

    /// The day key is part of an item's identity for the life of the install,
    /// so it must not be built by a locale-sensitive formatter.
    @Test func dayKeyIsStableAndZeroPadded() {
        #expect(
            TodoItemMapper.dayKey(date("2026-01-05T23:30:00Z"), calendar: utc)
                == "2026-01-05")
    }

    /// The write-through is handed the *queue's* id, which for a recurring
    /// task is not the provider's id.
    @Test func payloadRecoversTheProviderIdentifier() {
        let recurring = task(due: date("2026-08-26T13:00:00Z"), recurring: true)
        let item = TodoItemMapper.remoteItem(
            from: recurring, now: date("2026-08-26T14:00:00Z"), calendar: utc)

        #expect(item.externalID == "TASK-1#2026-08-26")
        #expect(
            TodoPayload.providerID(
                externalID: item.externalID, payload: item.payload) == "TASK-1")
        // And still works when the payload is missing entirely, rather than
        // completing nothing at all.
        #expect(
            TodoPayload.providerID(externalID: item.externalID, payload: nil)
                == "TASK-1")
    }
}

struct TodoClassificationTests {

    /// 5 of 8 of Brandon's due-today reminders are all-day. Treating an
    /// all-day task as overdue from 00:00 would mislabel most of them.
    @Test func allDayTaskIsNotOverdueUntilItsDayIsOver() {
        let due = date("2026-08-26T00:00:00Z")
        #expect(
            !TodoItemMapper.isOverdue(
                due: due, isAllDay: true, now: date("2026-08-26T23:59:00Z"),
                calendar: utc))
        #expect(
            TodoItemMapper.isOverdue(
                due: due, isAllDay: true, now: date("2026-08-27T00:00:00Z"),
                calendar: utc))
    }

    @Test func timedTaskIsOverdueAtItsDueMoment() {
        let due = date("2026-08-26T13:50:00Z")
        #expect(
            !TodoItemMapper.isOverdue(
                due: due, isAllDay: false, now: date("2026-08-26T13:49:00Z"),
                calendar: utc))
        #expect(
            TodoItemMapper.isOverdue(
                due: due, isAllDay: false, now: date("2026-08-26T13:51:00Z"),
                calendar: utc))
    }

    @Test func kindNamesTheThreeStates() {
        let now = date("2026-08-26T14:00:00Z")
        #expect(
            TodoItemMapper.kind(
                for: task(due: date("2026-08-20T09:00:00Z")), now: now,
                calendar: utc) == "todo_overdue")
        #expect(
            TodoItemMapper.kind(
                for: task(due: date("2026-08-26T17:00:00Z")), now: now,
                calendar: utc) == "todo_due")
        #expect(
            TodoItemMapper.kind(
                for: task(due: date("2026-08-30T17:00:00Z")), now: now,
                calendar: utc) == "todo_later")
        #expect(
            TodoItemMapper.kind(for: task(), now: now, calendar: utc)
                == "todo_open")
    }

    /// Overdue is the signal; "due today" is not, or the high-signal badge
    /// would just mean "you have a to-do list".
    @Test func onlyOverdueAndHighPriorityAreHighSignal() {
        let now = date("2026-08-26T14:00:00Z")
        #expect(
            TodoItemMapper.highSignal(
                for: task(due: date("2026-08-20T09:00:00Z")), now: now,
                calendar: utc))
        #expect(
            !TodoItemMapper.highSignal(
                for: task(due: date("2026-08-26T17:00:00Z")), now: now,
                calendar: utc))
        #expect(
            !TodoItemMapper.highSignal(for: task(), now: now, calendar: utc))
        #expect(
            TodoItemMapper.highSignal(
                for: task(priority: .high), now: now, calendar: utc))
    }

    /// Measured EventKit bands: 1–4 high, 5 medium, 6–9 low, 0 unset. Not a
    /// linear scale, so not arithmetic.
    @Test func eventKitPriorityBandsMapCorrectly() {
        #expect(TodoPriority.fromEventKit(0) == .none)
        #expect(TodoPriority.fromEventKit(1) == .high)
        #expect(TodoPriority.fromEventKit(4) == .high)
        #expect(TodoPriority.fromEventKit(5) == .medium)
        #expect(TodoPriority.fromEventKit(9) == .low)
    }

    /// The title carries the task and the notes carry the body — the lesson
    /// from Slack's saved messages, where a preview in the title left `D`
    /// with nothing to reveal.
    @Test func notesBecomeTheSnippetUncapped() {
        let long = String(repeating: "x", count: 3_000)
        let item = TodoItemMapper.remoteItem(
            from: task(title: "Renew passport", notes: long, list: "Family"),
            now: date("2026-08-26T14:00:00Z"), calendar: utc)

        #expect(item.title == "Renew passport")
        #expect(item.snippet?.count == 3_000)
        #expect(item.actorName == "Family")
    }

    @Test func emptyTitleStillNamesTheRow() {
        let item = TodoItemMapper.remoteItem(
            from: task(title: ""), now: date("2026-08-26T14:00:00Z"),
            calendar: utc)
        #expect(item.title == "Untitled reminder")
    }
}

struct TodoScopeTests {

    /// The measured off-by-one. EventKit's `ending:` bound is inclusive and
    /// all-day reminders sit at 00:00 local, so the start of tomorrow pulled
    /// in a task due *tomorrow*.
    @Test func dueWindowExcludesAnAllDayTaskDueTomorrow() {
        let now = date("2026-08-26T14:00:00Z")
        let end = TodoScope.dueWindowEnd(now: now, calendar: utc)
        let startOfTomorrow = date("2026-08-27T00:00:00Z")

        #expect(end < startOfTomorrow)
        let scope = TodoScope(includesDueWindow: true)
        #expect(
            !scope.accepts(
                task(due: startOfTomorrow, allDay: true), now: now,
                calendar: utc))
        #expect(
            scope.accepts(
                task(due: date("2026-08-26T00:00:00Z"), allDay: true), now: now,
                calendar: utc))
    }

    @Test func dueWindowIncludesOverdueHoweverOld() {
        let scope = TodoScope(includesDueWindow: true)
        #expect(
            scope.accepts(
                task(due: date("2025-01-01T09:00:00Z")),
                now: date("2026-08-26T14:00:00Z"), calendar: utc))
    }

    /// Brandon's call: a chosen list contributes only its dated tasks unless
    /// the toggle is on. 70 of 135 open reminders here are undated.
    @Test func chosenListsAreDatedOnlyUnlessToldOtherwise() {
        let now = date("2026-08-26T14:00:00Z")
        let undated = task(list: "Maintenance")
        let dated = task(list: "Maintenance", due: date("2026-09-30T09:00:00Z"))

        let datedOnly = TodoScope(
            includesDueWindow: false, listNames: ["Maintenance"])
        #expect(!datedOnly.accepts(undated, now: now, calendar: utc))
        #expect(datedOnly.accepts(dated, now: now, calendar: utc))

        let everything = TodoScope(
            includesDueWindow: false, listNames: ["Maintenance"],
            listsIncludeUndated: true)
        #expect(everything.accepts(undated, now: now, calendar: utc))
    }

    @Test func listMatchingIgnoresCase() {
        let scope = TodoScope(
            includesDueWindow: false, listNames: ["house projects"])
        #expect(scope.includesList("House Projects"))
        #expect(!scope.includesList("Housework"))
    }

    /// A task in a list nobody picked, not due soon, is nobody's business.
    @Test func unpickedListOutsideTheWindowIsRefused() {
        let scope = TodoScope(includesDueWindow: true, listNames: ["Buffer"])
        #expect(
            !scope.accepts(
                task(list: "Wishlist", due: date("2026-12-01T09:00:00Z")),
                now: date("2026-08-26T14:00:00Z"), calendar: utc))
    }

    @Test func parsingTrimsBlanksAndDuplicates() {
        let names = TodoScope.parseListNames(" Buffer , , family ,BUFFER, Home ")
        #expect(names == ["Buffer", "family", "Home"])
        #expect(TodoScope.parseListNames("").isEmpty)
    }

    /// A source with neither mode on can only ever be empty, and the editor
    /// needs to be able to say so rather than looking broken.
    @Test func emptyScopeIsRecognised() {
        #expect(TodoScope(includesDueWindow: false).isEmpty)
        #expect(!TodoScope(includesDueWindow: true).isEmpty)
        #expect(
            !TodoScope(includesDueWindow: false, listNames: ["Buffer"]).isEmpty)
    }
}
