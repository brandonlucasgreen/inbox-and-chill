import Foundation
import Testing

@testable import InboxAndChill

@MainActor
struct PanelMarksTests {
    private func item(_ uid: String) -> Item {
        Item(
            uid: uid, sourceID: "s", sourceKind: "ntfy", kind: "message",
            title: uid, occurredAt: .now)
    }

    @Test func toggleAddsThenRemoves() {
        let marks = PanelMarks()
        #expect(marks.isEmpty)
        marks.toggle("a")
        #expect(marks.contains("a"))
        marks.toggle("b")
        #expect(marks.uids == ["a", "b"])
        marks.toggle("a")
        #expect(marks.uids == ["b"])
        marks.clear()
        #expect(marks.isEmpty)
    }

    /// A poll can archive a marked row between the mark and the verb. The
    /// verb acts on what is still in the queue, in queue order, not on the
    /// stale uid.
    @Test func liveFiltersToRowsStillQueued() {
        let marks = PanelMarks()
        marks.toggle("gone")
        marks.toggle("c")
        marks.toggle("a")
        let live = marks.live(in: [item("a"), item("b"), item("c")])
        #expect(live.map(\.uid) == ["a", "c"])
        #expect(marks.live(in: []).isEmpty)
    }
}
