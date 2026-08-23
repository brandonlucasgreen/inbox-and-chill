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
///
/// `isFull` is the third state, and the reason the 4-line clamp is allowed
/// to stay tight: D drops the clamp entirely, so the paragraph a row opens
/// to never has to be the whole message. It follows the same rule as the
/// other two — the unlimited copy is laid out and measured before the press,
/// so the frame still animates between two concrete numbers.
struct ExpandingText: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var collapsedLines: Int = 1
    let expandedLines: Int
    let isExpanded: Bool
    /// The selected row, opened the rest of the way with D: no clamp at all.
    /// Only meaningful while `isExpanded` — an unselected row is always on
    /// its one line.
    var isFull: Bool = false
    let animation: Animation?

    @State private var collapsedHeight: CGFloat?
    @State private var expandedHeight: CGFloat?
    @State private var fullHeight: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            label(lines: collapsedLines, of: Self.clampedPrefix(
                text, lines: collapsedLines))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    collapsedHeight = $0
                }
                .opacity(isExpanded ? 0 : 1)
                // The open copy carries the same string; without this
                // VoiceOver reads every row twice.
                .accessibilityHidden(true)
            label(lines: expandedLines, of: Self.clampedPrefix(
                text, lines: expandedLines))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    expandedHeight = $0
                }
                .opacity(isExpanded && !isFull ? 1 : 0)
                .accessibilityHidden(isFull)
            // The unlimited copy, and the only one that is conditional.
            //
            // It joins the layout for the selected row alone, because it is
            // the one copy with no line limit — laying it out for every row
            // would mean laying out every character of every body in the
            // queue, and a 4-line clamp is exactly what keeps that cost
            // proportional to what is on screen.
            //
            // And not until `expandedHeight` exists, which is subtler: with
            // nothing measured the clamp falls through to the stack's
            // natural height, and this copy would *be* that height. A row
            // that scrolls in already selected would paint its whole
            // message for a frame and then snap back to four lines.
            if isExpanded && (isFull || expandedHeight != nil) {
                label(lines: nil, of: text)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height }
                        action: { fullHeight = $0 }
                    .opacity(isFull ? 1 : 0)
                    .accessibilityHidden(!isFull)
            }
        }
        .frame(height: clamp, alignment: .topLeading)
        .clipped()
        .animation(animation, value: isExpanded)
        .animation(animation, value: isFull)
    }

    /// `fixedSize` is what makes this ignore the height it is offered and
    /// lay itself out at its own — the clamp above can then be any height at
    /// all without the text re-wrapping to fit it.
    private func label(lines: Int?, of string: String) -> some View {
        Text(string)
            .font(.system(size: size, weight: weight))
            .lineLimit(lines)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The most a clamped copy is ever allowed to see.
    ///
    /// A copy clamped to N lines can only *show* a few hundred characters,
    /// but `Text` lays out whatever string it is handed regardless — and the
    /// two clamped copies are laid out for **every row on screen**. Once a
    /// connector is allowed to store a whole Slack message, that becomes
    /// thousands of characters laid out per row per pass to render four
    /// lines. Only the unlimited copy — which exists for the selected row
    /// alone — is handed the entire string.
    ///
    /// `charsPerLine` is deliberately several times the ~55 characters that
    /// actually fit a 420pt panel row: the clamp has to stay the thing that
    /// truncates, so that the "…" still appears and still means "there is
    /// more". A prefix tight enough to become the truncation point would put
    /// an ellipsis on text that had already ended.
    nonisolated static func clampedPrefix(
        _ text: String, lines: Int, charsPerLine: Int = 240
    ) -> String {
        let budget = max(lines, 1) * charsPerLine
        guard text.count > budget else { return text }
        return String(text.prefix(budget))
    }

    private var clamp: CGFloat? {
        Self.clamp(
            isExpanded: isExpanded, isFull: isFull,
            collapsed: collapsedHeight, expanded: expandedHeight,
            full: fullHeight,
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
    /// - A full row falls back to its natural height too, on the same
    ///   argument: the unlimited copy is in the stack by then, so natural
    ///   *is* full.
    ///
    /// `full` is measured ahead of the press rather than after it, which is
    /// what makes D animate rather than jump. The unlimited copy is laid out
    /// (invisibly) as soon as the row takes the selection, so both heights
    /// are already concrete numbers when the flag flips and the frame has
    /// something to interpolate. A height that only arrived from a geometry
    /// callback would land on the pass *after* the transaction, by which
    /// time there is no animation left to join.
    nonisolated static func clamp(
        isExpanded: Bool, isFull: Bool = false, collapsed: CGFloat?,
        expanded: CGFloat?, full: CGFloat? = nil, estimate: CGFloat
    ) -> CGFloat? {
        if isExpanded && isFull { return full }
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
