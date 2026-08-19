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
            .accessibilityAction(
                named: item.isSeen ? "Mark unread" : "Mark read"
            ) {
                appState.toggleSeen(item)
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
                .fill(item.isSeen ? .clear : Color.accentColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Image(systemName: display.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(
                        .system(
                            size: 13,
                            weight: item.highSignal ? .semibold : .regular))
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(background)
    }

    @ViewBuilder private var trailing: some View {
        if isHovering {
            HStack(spacing: 2) {
                actionButton(
                    "arrow.up.forward.app", key: "⏎", "Open (⏎)", "Open"
                ) {
                    appState.open(item)
                }
                actionButton(
                    "checkmark.circle", key: "E", "Done (E)", "Mark done"
                ) {
                    appState.markDone(item)
                }
                SnoozeMenu(
                    apply: { appState.snooze(item, until: $0) },
                    pickDate: { snoozeTargetUID = item.uid })
                actionButton(
                    item.isSeen ? "envelope.badge" : "envelope.open",
                    key: "U",
                    item.isSeen ? "Mark unread (U)" : "Mark read (U)",
                    item.isSeen ? "Mark unread" : "Mark read"
                ) { appState.toggleSeen(item) }
                actionButton(
                    item.isPinned ? "pin.slash" : "pin", key: "⌘P",
                    item.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)",
                    item.isPinned ? "Unpin" : "Pin"
                ) { appState.togglePin(item) }
            }
            .font(.system(size: 14))
            .buttonStyle(.borderless)
            .transition(.opacity)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(timeText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .help(PanelFormat.full(item.occurredAt))
        }
    }

    /// Icon plus its keyboard shortcut, side by side. The key used to live
    /// only in the tooltip, which meant discovering it required hovering a
    /// row, then hovering an icon, then waiting — so in practice nobody found
    /// the keys. Printing them next to the glyph is the whole point.
    private func actionButton(
        _ systemImage: String, key: String, _ help: String, _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                KeyCap(key)
            }
            // Icon-only buttons need an explicit frame — the bare glyph's
            // bounds make a fiddly ~14pt hit target.
            .padding(.horizontal, 4)
            .frame(height: 24)
            .contentShape(.rect)
        }
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
        Button(item.isSeen ? "Mark as Unread" : "Mark as Read") {
            appState.toggleSeen(item)
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
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let focus = RowFocus.resolve(
            isSelected: isSelected, isHovering: isHovering,
            isKey: controlActiveState == .key)
        return ZStack {
            if focus.hasBaseFill { shape.fill(.quaternary) }
            if focus.fill > 0 { shape.fill(Color.primary.opacity(focus.fill)) }
            if focus.border > 0 {
                shape.strokeBorder(
                    Color.primary.opacity(focus.border), lineWidth: 1)
            }
        }
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
        if !item.isSeen { text += ", unseen" }
        if item.highSignal { text += ", high signal" }
        return text
    }

    private var snoozePopoverBinding: Binding<Bool> {
        Binding(
            get: { snoozeTargetUID == item.uid },
            set: { if !$0 { snoozeTargetUID = nil } })
    }
}


/// A shortcut key rendered as a small keycap. Deliberately quiet — it's a
/// hint sitting next to the control it describes, not a label competing with
/// the item's title.
struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            // Every other cap is a single glyph; "⌘P" is two, and the trailing
            // action stack was squeezing it down to a lone ellipsis. A cap is
            // useless if it can't show its key.
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.quaternary))
            .accessibilityHidden(true)
    }
}
