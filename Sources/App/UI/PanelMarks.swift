import SwiftUI

/// The rows marked for a bulk verb, held outside `PanelView`'s body.
///
/// Marks used to be a `@State var marks: Set<String>` on the panel, and every
/// toggle therefore re-ran the whole panel: the queue was rebuilt from
/// scratch, the filter bar, footer and every row on screen were re-evaluated
/// and the `LazyVStack` re-laid out — for a checkbox. As an `@Observable`
/// object the dependency is inverted: only the views that *read* the set
/// (each row's checkbox, and `MarksBar`) re-render when it changes, and the
/// panel's body does not run at all. The panel still reads it freely from
/// key handlers, because a read outside a body registers no dependency.
@MainActor @Observable
final class PanelMarks {
    private(set) var uids: Set<String> = []

    var isEmpty: Bool { uids.isEmpty }

    func contains(_ uid: String) -> Bool { uids.contains(uid) }

    /// An explicit toggle (Space, ⌘-click, the checkbox) also ends any ⇧-run,
    /// so the next ⇧-arrow builds on what is marked now rather than on what
    /// was marked when the run began.
    func toggle(_ uid: String) {
        endRange()
        if uids.remove(uid) == nil { uids.insert(uid) }
    }

    /// Space on a fold header: mark everything in it. Adds rather than
    /// toggles, so pressing it on two folds marks both.
    func mark(_ newUIDs: [String]) {
        endRange()
        uids.formUnion(newUIDs)
    }

    func clear() {
        endRange()
        guard !uids.isEmpty else { return }
        uids.removeAll()
    }

    // MARK: Shift-selection

    /// Where a ⇧↑/⇧↓ run started, and what was marked before it did. The
    /// marks are always `rangeBase ∪ range(anchor…selection)`, which is what
    /// lets ⇧↑ after ⇧↓ take a row back out rather than pile on — the same
    /// contract as Shift-arrow in every list on the platform.
    private var rangeAnchor: String?
    private var rangeBase: Set<String> = []

    /// ⇧↑/⇧↓: the selection has just moved from `previous` to `target`.
    /// Starts a run at `previous` if one isn't in progress.
    func extendRange(from previous: String, to target: String, in visible: [String]) {
        if rangeAnchor == nil {
            rangeAnchor = previous
            rangeBase = uids
        }
        uids = rangeBase.union(
            Self.range(in: visible, from: rangeAnchor ?? previous, to: target))
    }

    /// Any selection move that is not a ⇧-arrow ends the run, so the next one
    /// starts from wherever the selection is then.
    func endRange() {
        rangeAnchor = nil
        rangeBase = []
    }

    /// The item rows between two row ids, inclusive, in on-screen order.
    /// Topic headers are skipped: a header stands for its members and cannot
    /// itself be marked (see `PanelView.toggleMarkSelected`). An anchor that
    /// has left the queue collapses the range to the target alone.
    nonisolated static func range(
        in visible: [String], from anchor: String, to target: String
    ) -> [String] {
        guard let t = visible.firstIndex(of: target) else { return [] }
        let a = visible.firstIndex(of: anchor) ?? t
        return visible[min(a, t)...max(a, t)].filter {
            QueueRowID.topicID(from: $0) == nil
        }
    }

    /// The marked rows still in `items`.
    ///
    /// Filtered against the live query rather than trusted: a poll can
    /// archive a marked row, and acting on a uid that has left the queue is
    /// how a bulk verb quietly does less than it says.
    func live(in items: [Item]) -> [Item] {
        guard !uids.isEmpty else { return [] }
        return items.filter { uids.contains($0.uid) }
    }
}

/// The mark checkbox: a continuous-corner square, the shape every checkbox
/// on this platform has. The first build drew a circle, which read as a
/// radio button or an iOS control rather than something a Mac user would
/// expect to tick.
struct MarkBox: View {
    let isMarked: Bool
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(isMarked ? Color.accentColor : .clear)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(
                    isMarked ? .clear : Color.primary.opacity(0.28),
                    lineWidth: 1)
            if isMarked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}
