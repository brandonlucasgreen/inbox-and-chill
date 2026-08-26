import Foundation

/// Turns a `TodoTask` into a `RemoteItem`. All of it pure, all of it tested.
///
/// This file is where "a to-do is not a notification" actually gets decided,
/// and both decisions in it were arrived at by measuring EventKit rather than
/// reasoning about it (2026-08-26; the numbers are in
/// `docs/todo-sources-plan.md`).
///
/// ## Why `occurredAt` is not the due date
///
/// `Store.resurrectIfNeeded` revives a done item when
/// `remote.occurredAt > item.doneAt`. A task's due date is usually in the
/// *future*, so using it would mean a reminder due at 5pm that you dismissed
/// at 2pm comes straight back on the next poll — and dismissal is the one
/// behaviour this source was asked for. Anything derived from `now`
/// (start-of-today, say) fails differently: it moves at midnight, so a
/// dismissed task returns every morning. So `occurredAt` has to be a fixed
/// point in the task's *own* history, and it is `modifiedAt`.
///
/// ## Why the external id carries the occurrence
///
/// The first version of this file stopped at the paragraph above, on the
/// assumption that a recurrence rolling over would revive the row because
/// `lastModifiedDate` moves with it. **It does not.** Measured: completing a
/// daily reminder rolled its due date from today to tomorrow and left
/// `lastModifiedDate` untouched. With a stable id and a stable `occurredAt`,
/// that means a repeating task would be marked done once and **never appear
/// again** — the row for "water the plants" would vanish in week one, silently.
///
/// So identity does the work instead: a recurring task's external id carries
/// the day it is due, and tomorrow's occurrence is simply a different item.
/// Only one occurrence is ever inside the fetch window at a time, so this is
/// one row per day and not a pile.
///
/// **A neglected occurrence is not replaced.** Measured separately: an
/// uncompleted recurring reminder does *not* roll forward — it stays at its
/// original due date, keeps its identifier, and simply goes overdue. Only
/// completion advances the series. So the day suffix is stable for as long as
/// you ignore the task, which is what makes "I skipped this yesterday" survive
/// in the queue instead of vanishing at midnight, and why this design adds no
/// per-day archive row.
///
/// This is the **inverse** of the `claude-done-<session>-<epoch>` bug that
/// `Store` and the local connector were reshaped around, and it is worth not
/// confusing the two: there, a timestamp in the id shattered one long-lived
/// thing into thirty rows. Here each occurrence genuinely is a separate
/// commitment, and the suffix is a *day*, not an event time. Non-recurring
/// tasks keep a bare id on purpose, so editing a due date updates the row in
/// place rather than orphaning it.
enum TodoItemMapper {

    /// Separates a recurring task's id from its occurrence day. `#` is safe
    /// here: EventKit identifiers are UUIDs, and Todoist's are opaque
    /// alphanumeric strings like `6XGgmFVcrG5RRjVr` — checked against
    /// Todoist's published schema on 2026-08-26, which corrects the earlier
    /// note here that they were digits. Neither alphabet contains `#`.
    static let occurrenceSeparator: Character = "#"

    // MARK: Identity

    /// The queue's external id for a task.
    nonisolated static func externalID(
        for task: TodoTask, calendar: Calendar = .current
    ) -> String {
        // A recurring task with no due date has no occurrence to name, so it
        // keeps the bare id rather than getting a meaningless suffix.
        guard task.isRecurring, let due = task.due else { return task.providerID }
        return "\(task.providerID)\(occurrenceSeparator)\(dayKey(due, calendar: calendar))"
    }

    /// `2026-08-26`, built from calendar components rather than a
    /// `DateFormatter` so it cannot drift with the user's locale — this string
    /// is part of an item's identity and has to be stable for the life of the
    /// install.
    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current)
        -> String
    {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0)
    }

    // MARK: Timestamp

    /// When the task last changed — never a moment in the future.
    ///
    /// The clamp is the regression guard for the dismissal bug described
    /// above. It only ever bites in the fallback case (a provider that reports
    /// neither a modified nor a created date); EventKit always supplies both.
    nonisolated static func occurredAt(for task: TodoTask, now: Date = .now)
        -> Date
    {
        let candidate = task.modifiedAt ?? task.createdAt ?? task.due ?? now
        return min(candidate, now)
    }

    // MARK: Classification

    /// The semantic kind, refreshed on every poll by `Store.update` — so an
    /// item that was `todo_due` this morning is `todo_overdue` this evening
    /// without anything having to track the transition.
    nonisolated static func kind(
        for task: TodoTask, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        guard let due = task.due else { return "todo_open" }
        if isOverdue(due: due, isAllDay: task.isAllDay, now: now, calendar: calendar) {
            return "todo_overdue"
        }
        return calendar.isDate(due, inSameDayAs: now) ? "todo_due" : "todo_later"
    }

    /// An all-day task is not overdue until its day is over.
    ///
    /// Without this, every all-day reminder due today reads as overdue from
    /// 00:00 — and measured, 5 of 8 of Brandon's due-today reminders are
    /// all-day, so this would have mislabelled most of them.
    nonisolated static func isOverdue(
        due: Date, isAllDay: Bool, now: Date, calendar: Calendar = .current
    ) -> Bool {
        guard isAllDay else { return due < now }
        guard let endOfDueDay = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: due))
        else { return due < now }
        return endOfDueDay <= now
    }

    /// Counts toward the high-signal badge.
    ///
    /// Overdue only, plus an explicit high priority. Deliberately *not* every
    /// task due today: the due-today window is the main mode, so treating it
    /// as high-signal would make the high-signal badge mean "you have a to-do
    /// list", which is not news. Priority is included but carries no weight in
    /// practice — measured, every reminder on this Mac has priority unset.
    nonisolated static func highSignal(
        for task: TodoTask, now: Date = .now, calendar: Calendar = .current
    ) -> Bool {
        if task.priority == .high { return true }
        guard let due = task.due else { return false }
        return isOverdue(
            due: due, isAllDay: task.isAllDay, now: now, calendar: calendar)
    }

    // MARK: Ordering

    /// Most urgent first, so a connector's snapshot cap drops the least
    /// urgent tasks rather than whatever the provider happened to answer last.
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

    // MARK: Assembly

    nonisolated static func remoteItem(
        from task: TodoTask, now: Date = .now, calendar: Calendar = .current
    ) -> RemoteItem {
        RemoteItem(
            externalID: externalID(for: task, calendar: calendar),
            kind: kind(for: task, now: now, calendar: calendar),
            // The title is the task, and the notes are the body. Never a
            // preview in the title — that is what made Slack's saved messages
            // impossible to expand.
            title: task.title.isEmpty ? "Untitled reminder" : task.title,
            snippet: task.notes?.isEmpty == false ? task.notes : nil,
            url: task.deepLink,
            // The list is the closest thing a task has to a sender, and the
            // row already renders `actorName` in that slot.
            actorName: task.listName,
            occurredAt: occurredAt(for: task, now: now),
            highSignal: highSignal(for: task, now: now, calendar: calendar),
            payload: TodoPayload(from: task).encoded())
    }

    // MARK: Presentation

    /// "Due today", "Overdue by 2 days", "Due Thu 2:50 PM" — the chip text for
    /// an expanded row.
    ///
    /// This exists because of the `occurredAt` decision: the queue's Age
    /// column now reflects when the task last *changed*, so the due date has
    /// to be readable somewhere, and this is that somewhere.
    nonisolated static func dueDescription(
        for task: TodoTask, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        guard let due = task.due else { return "No due date" }
        let overdue = isOverdue(
            due: due, isAllDay: task.isAllDay, now: now, calendar: calendar)
        if calendar.isDate(due, inSameDayAs: now) {
            // An all-day task due today is never overdue — `isOverdue` waits
            // for the day to end — so there is only one thing to say.
            guard !task.isAllDay else { return "Due today" }
            let time = due.formatted(date: .omitted, time: .shortened)
            return overdue ? "Overdue — was due \(time)" : "Due \(time)"
        }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: due),
            to: calendar.startOfDay(for: now)).day ?? 0
        if overdue {
            return days == 1 ? "Overdue by a day" : "Overdue by \(days) days"
        }
        let stamp = task.isAllDay
            ? due.formatted(date: .abbreviated, time: .omitted)
            : due.formatted(date: .abbreviated, time: .shortened)
        return "Due \(stamp)"
    }
}
