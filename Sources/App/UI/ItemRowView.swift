import AppKit
import SwiftUI

/// One queue row: source glyph, title, snippet/actor, relative time, and
/// hover-revealed quick actions (Open · Done · Snooze ▾ · Pin).
struct ItemRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var controlActiveState
    let item: Item
    let display: SourceDisplay
    let isSelected: Bool
    /// Which row currently owns the snooze popover (S key or "Pick Date…").
    @Binding var snoozeTargetUID: String?
    var onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        draggableContent
            .contentShape(.rect)
            // Double-tap must be declared first to win over the single tap.
            .onTapGesture(count: 2) {
                onSelect()
                appState.open(item)
            }
            .onTapGesture { onSelect() }
            .onHover { isHovering = $0 }
            .contextMenu { contextMenu }
            .popover(isPresented: snoozePopoverBinding, arrowEdge: .trailing) {
                SnoozePopover(title: item.title) { date in
                    snoozeTargetUID = nil
                    appState.snooze(item, until: date)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            // Hover-only quick actions have no VoiceOver equivalent without
            // these — expose the same actions regardless of hover state.
            .accessibilityAction(named: "Open") { appState.open(item) }
            .accessibilityAction(named: "Mark Done") { appState.markDone(item) }
            .accessibilityAction(named: "Snooze 3 Hours") {
                appState.snooze(item, until: SnoozePreset.laterToday.date())
            }
            .accessibilityAction(named: item.isPinned ? "Unpin" : "Pin") {
                appState.togglePin(item)
            }
    }

    // MARK: Layout

    @ViewBuilder private var draggableContent: some View {
        if let url = item.url {
            row.draggable(url)
        } else {
            row.draggable(item.title)
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.highSignal ? Color.accentColor : .clear)
                .frame(width: 5, height: 5)
                .padding(.top, 5)
                .accessibilityHidden(true)
            Image(systemName: display.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(
                        .system(
                            size: 12,
                            weight: item.highSignal ? .semibold : .regular))
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(background)
    }

    @ViewBuilder private var trailing: some View {
        if isHovering {
            HStack(spacing: 2) {
                actionButton("arrow.up.forward.app", "Open (⏎)", "Open") {
                    appState.open(item)
                }
                actionButton("checkmark.circle", "Done (E)", "Mark done") {
                    appState.markDone(item)
                }
                SnoozeMenu(
                    apply: { appState.snooze(item, until: $0) },
                    pickDate: { snoozeTargetUID = item.uid })
                actionButton(
                    item.isPinned ? "pin.slash" : "pin",
                    item.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)",
                    item.isPinned ? "Unpin" : "Pin"
                ) { appState.togglePin(item) }
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .transition(.opacity)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(timeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .help(PanelFormat.full(item.occurredAt))
        }
    }

    private func actionButton(
        _ systemImage: String, _ help: String, _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: systemImage) }
            .help(help)
            .accessibilityLabel(Text(label))
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Open") { appState.open(item) }
        Button("Open and Mark Done") {
            appState.open(item)
            appState.markDone(item)
        }
        Divider()
        Button("Mark Done") { appState.markDone(item) }
        Menu("Snooze") {
            ForEach(SnoozePreset.allCases) { preset in
                Button("\(preset.title) (\(preset.detail))") {
                    appState.snooze(item, until: preset.date())
                }
            }
            Divider()
            Button("Pick Date…") { snoozeTargetUID = item.uid }
        }
        Button(item.isPinned ? "Unpin" : "Pin") { appState.togglePin(item) }
        Divider()
        Button("Copy") {
            PanelPasteboard.copy(title: item.title, url: item.url)
        }
        if let url = item.url {
            Button("Copy Link") {
                PanelPasteboard.copy(title: item.title, url: url)
            }
        }
    }

    // MARK: Derived

    private var background: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fillStyle)
    }

    private var fillStyle: AnyShapeStyle {
        if isSelected {
            let color: NSColor =
                controlActiveState == .key
                ? .selectedContentBackgroundColor
                : .unemphasizedSelectedContentBackgroundColor
            return AnyShapeStyle(Color(nsColor: color))
        }
        if isHovering { return AnyShapeStyle(.quaternary) }
        return AnyShapeStyle(Color.clear)
    }

    private var secondary: String? {
        let parts = [item.actorName, item.snippet]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var timeText: String {
        if let until = item.snoozedUntil, item.isSnoozed {
            return PanelFormat.until(until)
        }
        return PanelFormat.relative(item.occurredAt)
    }

    private var accessibilityLabel: String {
        var text = "\(display.name): \(item.title)"
        if let secondary { text += ", \(secondary)" }
        text += ", \(PanelFormat.relative(item.occurredAt)) ago"
        if item.isPinned { text += ", pinned" }
        if item.highSignal { text += ", high signal" }
        return text
    }

    private var snoozePopoverBinding: Binding<Bool> {
        Binding(
            get: { snoozeTargetUID == item.uid },
            set: { if !$0 { snoozeTargetUID = nil } })
    }
}
