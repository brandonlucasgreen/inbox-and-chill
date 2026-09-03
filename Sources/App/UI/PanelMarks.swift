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

    func toggle(_ uid: String) {
        if uids.remove(uid) == nil { uids.insert(uid) }
    }

    func clear() {
        guard !uids.isEmpty else { return }
        uids.removeAll()
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
