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

    /// ⇧↓ marks the row left and the row landed on; ⇧↑ straight after takes
    /// the last one back out, because the range is anchored where the run
    /// began rather than accumulated. Marks made before the run survive it.
    @Test func shiftRunIsAnchoredNotAccumulated() {
        let visible = ["a", "b", "c", "d"]
        let marks = PanelMarks()
        marks.toggle("a")
        marks.extendRange(from: "b", to: "c", in: visible)
        #expect(marks.uids == ["a", "b", "c"])
        marks.extendRange(from: "c", to: "d", in: visible)
        #expect(marks.uids == ["a", "b", "c", "d"])
        marks.extendRange(from: "d", to: "c", in: visible)
        #expect(marks.uids == ["a", "b", "c"])
        marks.extendRange(from: "c", to: "b", in: visible)
        #expect(marks.uids == ["a", "b"])
        // Past the anchor in the other direction: the range flips around it.
        marks.extendRange(from: "b", to: "a", in: visible)
        #expect(marks.uids == ["a", "b"])
        // A plain move ends the run; the next ⇧-arrow starts a fresh one
        // from the current marks.
        marks.endRange()
        marks.extendRange(from: "d", to: "c", in: visible)
        #expect(marks.uids == ["a", "b", "c", "d"])
    }

    /// Topic headers sit in the keyboard order but cannot be marked, so a
    /// run through an open topic marks its members and skips the header.
    @Test func rangeSkipsTopicHeadersAndSurvivesAMissingAnchor() {
        let visible = ["a", QueueRowID.topic("t"), "m1", "m2", "b"]
        #expect(
            PanelMarks.range(in: visible, from: "a", to: "m2")
                == ["a", "m1", "m2"])
        #expect(PanelMarks.range(in: visible, from: "b", to: "m1") == ["m1", "m2", "b"])
        #expect(PanelMarks.range(in: visible, from: "gone", to: "b") == ["b"])
        #expect(PanelMarks.range(in: visible, from: "a", to: "gone").isEmpty)
        #expect(PanelMarks.range(in: visible, from: "a", to: QueueRowID.topic("t")) == ["a"])
    }
}
