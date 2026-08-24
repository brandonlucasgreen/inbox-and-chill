import SwiftUI

/// The context section of a fully-expanded row (D): chips, a conversation
/// fanned out around its focus message, stack frames, a blurb — whatever the
/// item's `ItemContext` carries, plus the loading and failure states.
///
/// One view for every source. Connectors decide *what* to say via
/// `ItemContext`'s typed sections; nothing here knows Slack from Sentry.
struct RowContextView: View {
    let phase: RowContextPhase

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("Fetching context…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
            .accessibilityLabel("Fetching context")
        case .failed(let reason):
            noteRow(reason, systemImage: "exclamationmark.triangle")
        case .loaded(let context):
            loaded(context)
        }
    }

    @ViewBuilder private func loaded(_ context: ItemContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !context.chips.isEmpty {
                ChipFlow(chips: context.chips)
            }
            if !context.messages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if let label = context.messagesLabel {
                        caption(label)
                    }
                    MessageFan(messages: context.messages)
                }
            }
            if !context.frames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if let label = context.framesLabel {
                        caption(label)
                    }
                    framesBlock(context.frames)
                }
            }
            if let blurb = context.blurb {
                VStack(alignment: .leading, spacing: 2) {
                    if let label = context.blurbLabel {
                        caption(label)
                    }
                    Text(blurb)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = context.note {
                noteRow(note, systemImage: "exclamationmark.triangle")
            }
        }
        .padding(.top, 2)
    }

    private func caption(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .kerning(0.4)
            .lineLimit(1)
    }

    private func framesBlock(_ frames: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                Text(frame)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
    }

    private func noteRow(_ text: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.top, 2)
    }
}

/// A conversation fanned out from its focus message — the mention sits
/// highlighted where it happened, earlier messages stack above it and later
/// ones below, fading with distance so the eye lands on the mention first.
/// (Brandon's design, 2026-08-23.)
private struct MessageFan: View {
    let messages: [ItemContext.Message]

    var body: some View {
        let focusIndex = messages.firstIndex(where: \.isFocus)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                row(message)
                    .opacity(opacity(index: index, focus: focusIndex))
            }
        }
    }

    /// 1.0 at the focus, stepping down 0.15 per message away, floored where
    /// text is still comfortably readable. No focus (a plain comment list)
    /// means no fade.
    private func opacity(index: Int, focus: Int?) -> Double {
        guard let focus else { return 1 }
        return max(0.55, 1 - 0.15 * Double(abs(index - focus)))
    }

    @ViewBuilder private func row(_ message: ItemContext.Message) -> some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(message.isFocus ? Color.accentColor : Color.primary.opacity(0.14))
                .frame(width: message.isFocus ? 3 : 2)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(message.author)
                    .font(.system(size: 11, weight: .semibold))
                Text(message.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(message.isFocus ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, message.isFocus ? 4 : 2)
        .padding(.horizontal, message.isFocus ? 6 : 0)
        .background {
            if message.isFocus {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
    }
}

/// Chips, wrapping onto further lines instead of truncating — four labels on
/// a busy PR must not cost the last one its name.
private struct ChipFlow: View {
    let chips: [ItemContext.Chip]

    var body: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                ChipView(chip: chip)
            }
        }
    }
}

private struct ChipView: View {
    let chip: ItemContext.Chip

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage = chip.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            if let dot = Color(hex: chip.dotHex) {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(chip.text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private var tint: Color {
        switch chip.tint {
        case .neutral: return .secondary
        case .orange: return .orange
        case .red: return .red
        case .green: return .green
        }
    }
}

extension Color {
    /// `"d73a4a"` or `"#d73a4a"` → a Color; nil for anything else. Label
    /// colors arrive from Linear and GitHub as hex strings.
    init?(hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty
        else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
