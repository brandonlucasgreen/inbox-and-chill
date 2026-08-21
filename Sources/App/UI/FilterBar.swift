import SwiftUI

/// Where panel key events go. The list keeps focus for triage keys; the
/// filter field only takes focus on ⌘F (or a click).
enum PanelFocus: Hashable {
    case list
    case filter
}

/// Scope control at the top of the panel: "All" plus one chip per source
/// that currently has queued items. ⌘1 = All, ⌘2…⌘9 = the chips in order.
/// The type-to-filter field lives here too, shown only while filtering.
struct FilterBar: View {
    let sources: [SourceDisplay]
    let counts: [String: Int]
    let totalCount: Int
    /// nil = All; otherwise a `SourceConfig.id` (sourceID).
    @Binding var selection: String?
    @Binding var filterText: String
    @Binding var isFiltering: Bool
    var focus: FocusState<PanelFocus?>.Binding
    var onClearFilter: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            FlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                chip(
                    label: "All", systemImage: "tray.2", count: totalCount,
                    isOn: selection == nil, shortcut: 1
                ) { selection = nil }
                ForEach(Array(sources.enumerated()), id: \.element.id) {
                    offset, source in
                    chip(
                        label: source.name,
                        systemImage: source.systemImage,
                        count: counts[source.id] ?? 0,
                        isOn: selection == source.id,
                        shortcut: offset + 2
                    ) { selection = source.id }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, isFiltering ? 0 : 6)

            if isFiltering {
                filterField
            }
        }
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Filter items", text: $filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(focus, equals: .filter)
                .accessibilityLabel("Filter items")
            Button(action: onClearFilter) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Clear filter (Esc)")
            .accessibilityLabel("Clear filter")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func chip(
        label: String, systemImage: String, count: Int, isOn: Bool,
        shortcut: Int, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(label).font(.system(size: 12))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    isOn ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                        : AnyShapeStyle(.quaternary)))
            .overlay(
                Capsule().strokeBorder(
                    isOn ? Color.accentColor.opacity(0.5) : .clear,
                    lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(OptionalCommandShortcut(digit: shortcut))
        .help(
            shortcut <= 9
                ? "Show \(label) (⌘\(shortcut))" : "Show \(label)")
        .accessibilityLabel("\(label) filter")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Lays out children left-to-right, wrapping onto a new row when the next
/// child no longer fits the available width — the source filter chips have
/// no fixed count, and a horizontally-scrolling row hid the ones that didn't
/// fit with no visible scrollbar and no way to reach them without knowing to
/// scroll. Wrapping means every chip is always on screen and clickable,
/// however many sources are configured.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + horizontalSpacing + size.width > width {
                totalHeight += lineHeight + verticalSpacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth > 0 ? horizontalSpacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: width.isFinite ? width : lineWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// ⌘1…⌘9 for the first nine chips; later chips are click-only.
private struct OptionalCommandShortcut: ViewModifier {
    let digit: Int

    func body(content: Content) -> some View {
        if digit >= 1, digit <= 9, let character = "\(digit)".first {
            content.keyboardShortcut(
                KeyEquivalent(character), modifiers: .command)
        } else {
            content
        }
    }
}
