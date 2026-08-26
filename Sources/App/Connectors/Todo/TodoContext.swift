import Foundation

/// The chips an expanded (`D`) to-do row shows, for every to-do provider.
///
/// Shared rather than written once per connector, because these chips exist to
/// answer a question the *design* creates rather than anything provider-specific:
/// `TodoItemMapper.occurredAt` deliberately reports when a task last changed,
/// not when it is due, so the queue's Age column cannot show the due date and
/// it has to be legible somewhere else. That reasoning is identical for
/// Reminders and Todoist, so a second copy could only drift.
///
/// Built lazily from `TodoPayload` on each expansion rather than stored — "Overdue
/// by 3 days" is wrong the moment it is written to a database.
enum TodoContext {

    nonisolated static func chips(from payload: TodoPayload, now: Date)
        -> ItemContext?
    {
        // A title-less stand-in: every function called below reads only the
        // date fields, and reconstructing the task keeps the overdue wording
        // in `TodoItemMapper` where the rest of the date logic lives.
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
