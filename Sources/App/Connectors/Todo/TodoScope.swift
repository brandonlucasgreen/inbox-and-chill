import Foundation

/// Which tasks a to-do source is asking for.
///
/// Two independent modes, OR'd, because Brandon asked for both: *"bring in
/// today/due reminders AND/OR reminders from specifically chosen lists"*.
/// Provider-agnostic on purpose — for Todoist "lists" are projects and
/// nothing else changes.
struct TodoScope: Sendable, Equatable {

    /// Everything due by the end of today, overdue included.
    var includesDueWindow: Bool
    /// Lists to pull in wholesale, by title.
    ///
    /// Titles rather than provider identifiers: they are readable in the
    /// settings JSON and in a bug report, and a title that no longer exists is
    /// something the editor can *say* (rule 5), where a stale opaque
    /// identifier would just quietly match nothing.
    var listNames: [String]
    /// Whether a chosen list contributes its undated tasks too.
    ///
    /// Off by default, and the default is the measurement: 70 of the 135 open
    /// reminders on this Mac have no due date and one list alone holds 36, so
    /// the unfiltered version buries the rest of the queue the moment you pick
    /// a list. Brandon's call, 2026-08-26.
    var listsIncludeUndated: Bool

    init(
        includesDueWindow: Bool = true, listNames: [String] = [],
        listsIncludeUndated: Bool = false
    ) {
        self.includesDueWindow = includesDueWindow
        self.listNames = listNames
        self.listsIncludeUndated = listsIncludeUndated
    }

    /// Nothing selected at all. Not an error, but a source in this state can
    /// only ever be empty, so the editor says so rather than letting it look
    /// like a broken connection.
    var isEmpty: Bool { !includesDueWindow && listNames.isEmpty }

    /// Parses the comma-separated settings field. Trims, drops blanks, and
    /// de-duplicates case-insensitively while keeping the user's own spelling
    /// and order.
    static func parseListNames(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",").compactMap { piece in
            let name = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else {
                return nil
            }
            return name
        }
    }

    /// Comma-separated form, for writing back to `settingsJSON`.
    static func joinListNames(_ names: [String]) -> String {
        names.joined(separator: ", ")
    }

    /// Whether this scope names a list, case-insensitively.
    func includesList(_ title: String) -> Bool {
        listNames.contains { $0.caseInsensitiveCompare(title) == .orderedSame }
    }

    // MARK: The due window

    /// The last instant that counts as "due today".
    ///
    /// **This is a measured off-by-one, not a paranoid `-1`.** EventKit's
    /// `predicateForIncompleteReminders(withDueDateStarting:ending:)` treats
    /// `ending:` as *inclusive*, and an all-day reminder is stored at 00:00
    /// local — so passing the start of tomorrow pulled a reminder due
    /// *tomorrow* into the due-today window when this was measured on
    /// 2026-08-26. One second earlier is the whole fix, and it lives here so
    /// there is exactly one place to get it right.
    static func dueWindowEnd(now: Date = .now, calendar: Calendar = .current)
        -> Date
    {
        let startOfTomorrow =
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            ?? now
        return startOfTomorrow.addingTimeInterval(-1)
    }

    // MARK: Filtering

    /// Whether a task the provider returned belongs in the queue.
    ///
    /// The provider is asked two narrower questions where it can be (a due
    /// window, a set of lists), but the two answers overlap and neither
    /// enforces `listsIncludeUndated`, so this is the single gate everything
    /// passes through before becoming an item.
    func accepts(
        _ task: TodoTask, now: Date = .now, calendar: Calendar = .current
    ) -> Bool {
        // Due window: anything due by the end of today, however old.
        if includesDueWindow, let due = task.due,
            due <= Self.dueWindowEnd(now: now, calendar: calendar)
        {
            return true
        }
        // Chosen lists: everything open in them, dated-only unless the toggle
        // is on.
        if let list = task.listName, includesList(list) {
            return task.due != nil || listsIncludeUndated
        }
        return false
    }
}
