import AppKit
import SwiftUI

/// How far a row opens while it holds the selection.
///
/// One line is enough to *recognise* a notification and almost never enough
/// to *act* on one — and acting without opening the source is the whole
/// point of the queue. Four lines of body is about a paragraph of Slack or
/// Linear, which is where "I know what this is asking" usually lands; two
/// lines of title covers the long `ENG-1234: …` headlines that were being
/// cut mid-sentence.
enum RowExpansion {
    static let titleLines = 2
    static let bodyLines = 4
}

/// A clamped label that opens to `expandedLines` while its row holds the
/// selection and closes back to `collapsedLines` when it loses it.
///
/// The type never reflows mid-animation. Both clamps are laid out at once
/// and cross-faded, while a `.clipped()` frame between them carries the
/// height — so the only thing moving is the window onto the text. Animating
/// `lineLimit` instead does the opposite: the glyphs re-wrap on every frame
/// and the ellipsis pops on and off mid-flight, which reads as a stutter
/// rather than as a row opening.
///
/// Keeping the closed copy is what preserves its "…". Clipping the open one
/// down to a line looks tidy but truncates silently — the row stops
/// mid-sentence with no sign there is more behind it, which is exactly the
/// thing this view exists to fix.
///
/// The closed height is measured rather than assumed, because a clamp a
/// point short crops the descenders off a single line; the font-metric
/// estimate is only what stands in until the first measurement lands. The
/// open height is measured too, but only so the frame animates between two
/// concrete numbers — until it is known the frame takes the text's natural
/// height, so a row that appears already open is the right size on its
/// first frame rather than jumping a beat later.
struct ExpandingText: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var collapsedLines: Int = 1
    let expandedLines: Int
    let isExpanded: Bool
    let animation: Animation?

    @State private var collapsedHeight: CGFloat?
    @State private var expandedHeight: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            label(lines: collapsedLines)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    collapsedHeight = $0
                }
                .opacity(isExpanded ? 0 : 1)
                // The open copy carries the same string; without this
                // VoiceOver reads every row twice.
                .accessibilityHidden(true)
            label(lines: expandedLines)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    expandedHeight = $0
                }
                .opacity(isExpanded ? 1 : 0)
        }
        .frame(height: clamp, alignment: .topLeading)
        .clipped()
        .animation(animation, value: isExpanded)
    }

    /// `fixedSize` is what makes this ignore the height it is offered and
    /// lay itself out at its own — the clamp above can then be any height at
    /// all without the text re-wrapping to fit it.
    private func label(lines: Int) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var clamp: CGFloat? {
        Self.clamp(
            isExpanded: isExpanded, collapsed: collapsedHeight,
            expanded: expandedHeight,
            estimate: Self.estimatedLineHeight(size: size)
                * CGFloat(collapsedLines))
    }

    /// The height the frame holds, given whatever has been measured so far.
    /// `nil` means "whatever the text needs", which is what `.frame` already
    /// takes it to mean.
    ///
    /// Pure, because the interesting cases happen before any measurement
    /// exists — a row scrolling into a `LazyVStack` paints at least one
    /// frame that way, and both have to be right:
    ///
    /// - An open row falls back to its natural height, not to the one-line
    ///   estimate. Clamping it early made it paint one line tall and then
    ///   jump to four, with no animation to explain the jump.
    /// - A closed row falls back to the estimate, not to zero.
    nonisolated static func clamp(
        isExpanded: Bool, collapsed: CGFloat?, expanded: CGFloat?,
        estimate: CGFloat
    ) -> CGFloat? {
        guard !isExpanded else { return expanded }
        let closed = collapsed ?? estimate
        guard let expanded else { return closed }
        // Text that already fits closed measures the same either way, so a
        // one-line snippet can't gain a gap under it.
        return min(closed, expanded)
    }

    /// First-paint height for one line, before anything has been measured.
    /// Weight is deliberately ignored: San Francisco's line height doesn't
    /// move with it, and threading an `NSFont.Weight` through would buy a
    /// value that is replaced on the next layout pass anyway.
    nonisolated static func estimatedLineHeight(size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return ceil(font.ascender - font.descender + font.leading)
    }
}
