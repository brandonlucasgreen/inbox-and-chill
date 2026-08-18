import SwiftUI

/// One control's self-description, shown as a bubble the panel draws itself.
///
/// Every footer control is icon-only, and each already carried `.help()` —
/// yet hovering the footer of the installed app showed nothing at all
/// (reported 2026-08-18). The likely cause is that the panel lives in a
/// non-activating status bar window, which never runs the tooltip tracking a
/// normal window does; either way the ordinary macOS tooltip cannot be relied
/// on here, so this is that tooltip re-implemented in-panel. It matters most
/// for the 7pt sync dots, where the colour is the whole message and a tooltip
/// was the only thing that could ever have explained it.
///
/// `.help()` is still applied alongside, so the same strings work wherever
/// these controls appear in a real window, and `accessibilityLabel` is
/// derived from the same source rather than repeated by hand.
struct PanelHint: Equatable, Hashable {
    /// What the control is or does, in plain words.
    var text: String
    /// Key equivalent, already glyph-formatted (`"⌘R"`), or nil if there
    /// isn't one.
    var shortcut: String?

    /// The single-line form, for `.help()` and VoiceOver.
    ///
    /// Pure and static so the tests can check it without a view: the panel's
    /// footer is the one place in the app where a wrong hint is invisible
    /// until someone hovers.
    nonisolated static func helpText(_ text: String, shortcut: String?) -> String {
        guard let shortcut, !shortcut.isEmpty else { return text }
        return "\(text) (\(shortcut))"
    }

    var helpText: String { Self.helpText(text, shortcut: shortcut) }
}

/// The hovered control's hint plus where it sits, handed up to the host.
struct PanelHintAnchor {
    var hint: PanelHint
    var bounds: Anchor<CGRect>
}

struct PanelHintAnchorKey: PreferenceKey {
    static let defaultValue: PanelHintAnchor? = nil

    static func reduce(
        value: inout PanelHintAnchor?, nextValue: () -> PanelHintAnchor?
    ) {
        // Only one control can be hovered, so first non-nil wins.
        value = value ?? nextValue()
    }
}

extension View {
    /// Describe this control on hover.
    ///
    /// - Parameter highlight: paint a hover chip behind the control too. On
    ///   for the icon buttons — an icon that doesn't react to the mouse reads
    ///   as decoration — off for the sync dots, which are 7pt and would be
    ///   swamped by it.
    func panelHint(
        _ text: String, shortcut: String? = nil, highlight: Bool = true,
        hovered: Binding<PanelHint?>
    ) -> some View {
        modifier(
            PanelHintTarget(
                hint: PanelHint(text: text, shortcut: shortcut),
                highlight: highlight, hovered: hovered))
    }

    /// Draw whichever hint is currently hovered, above this view.
    func panelHintHost(hovered: PanelHint?) -> some View {
        modifier(PanelHintHost(hovered: hovered))
    }
}

private struct PanelHintTarget: ViewModifier {
    let hint: PanelHint
    let highlight: Bool
    @Binding var hovered: PanelHint?
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                if highlight && isHovering {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary)
                }
            }
            .onHover { inside in
                isHovering = inside
                if inside {
                    hovered = hint
                } else if hovered == hint {
                    // Leaving for a neighbour: that control's `true` has
                    // already landed, so don't clear its hint from under it.
                    hovered = nil
                }
            }
            .anchorPreference(key: PanelHintAnchorKey.self, value: .bounds) {
                isHovering ? PanelHintAnchor(hint: hint, bounds: $0) : nil
            }
            .help(hint.helpText)
            .accessibilityLabel(Text(hint.text))
    }
}

private struct PanelHintHost: ViewModifier {
    let hovered: PanelHint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: PanelHint?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(PanelHintAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if let shown, let anchor, anchor.hint == shown {
                        bubble(shown, target: proxy[anchor.bounds],
                               within: proxy.size)
                    }
                }
            }
            .task(id: hovered) {
                guard let hovered else {
                    shown = nil
                    return
                }
                // Sweeping the mouse across the footer shouldn't flash a
                // bubble per control — but once one is up, the next reads as
                // the same bubble following the cursor, so switch instantly.
                if shown == nil {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { return }
                }
                shown = hovered
            }
    }

    private func bubble(
        _ hint: PanelHint, target: CGRect, within container: CGSize
    ) -> some View {
        PanelHintBubble(hint: hint)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .offset(x: originX(target: target, within: container),
                    y: -(size.height + 6))
            // Unmeasured, the bubble would land at the footer's top-left for
            // one frame before jumping into place.
            .opacity(size == .zero ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                       value: size)
            .transition(.opacity)
    }

    /// Centre the bubble on the control, then keep it inside the panel — the
    /// leftmost and rightmost footer controls are ~13pt from the edge, and a
    /// hint clipped by the window edge is worse than one slightly off-centre.
    private func originX(target: CGRect, within container: CGSize) -> CGFloat {
        let inset: CGFloat = 6
        let widest = container.width - inset * 2
        guard size.width <= widest else { return inset }
        let centred = target.midX - size.width / 2
        return min(max(centred, inset), container.width - size.width - inset)
    }
}

private struct PanelHintBubble: View {
    let hint: PanelHint

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(hint.text)
            if let shortcut = hint.shortcut {
                Text(shortcut).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        // Single line, sized to its text: a `maxWidth` frame would fill to
        // the cap and give "Settings" the same slab as the longest hint. The
        // hints are kept short enough to fit the 420pt panel instead —
        // `SourceStatusDot.describe` clamps the one string it can't control.
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.08)) }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .allowsHitTesting(false)
    }
}
