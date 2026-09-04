import AppKit
import SwiftUI

/// One queue row: source glyph, title, snippet/actor, relative time, and
/// hover-revealed quick actions (Expand · Open · Done · Snooze ▾ · Read ·
/// Pin).
struct ItemRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: Item
    let display: SourceDisplay
    let isSelected: Bool
    /// Whether the selected row is showing its whole message (D). Lives in
    /// the panel rather than here so it can only ever be true of one row,
    /// and so moving the selection puts it back.
    var isFullyExpanded: Bool = false
    /// Rendered inside an open topic — the source glyph is doing the job of
    /// the section header this row no longer sits under.
    var isTopicMember: Bool = false
    /// In a topic, but showing as a plain row anyway: the last member left
    /// after the others archived, or a source filter dissolving the group.
    /// Without the chip that row looks like it was never grouped.
    var showsTopicChip: Bool = false
    /// Which row currently owns the snooze popover (S key or "Pick Date…").
    @Binding var snoozeTargetUID: String?
    var onSelect: () -> Void
    /// Flips this row between the 4-line paragraph and the whole message,
    /// taking the selection first if it doesn't already hold it. Selecting
    /// here rather than at the call sites is what keeps the two out of one
    /// event — the panel closes a full expansion whenever the selection
    /// moves, so a separate `onSelect()` first would undo the toggle.
    var onToggleFull: () -> Void = {}
    var onToggleMark: () -> Void = {}
    var onGroup: () -> Void = {}

    /// Marked for a bulk verb. Read from the panel's `PanelMarks` rather
    /// than passed in, so a toggle re-renders this row and nothing above it.
    /// Optional because the main window and the archive render rows too,
    /// with no marks in their environment.
    @Environment(PanelMarks.self) private var marks: PanelMarks?

    @State private var isHovering = false

    private var isMarked: Bool { marks?.contains(item.uid) ?? false }

    var body: some View {
        draggableContent
            .contentShape(.rect)
            // One tap gesture, not a double-tap declared ahead of a single.
            // Stacking the two makes SwiftUI hold every single click until
            // the double-click interval (0.5s by default) has passed and the
            // second click has not come — so selecting and ⌘-marking rows
            // each landed half a second after the mouse went up. AppKit
            // already counts clicks; the event says whether this is the
            // second of a pair, and the first has been acted on by then.
            .onTapGesture {
                // ⌘-click extends a selection everywhere else on this
                // platform, so it marks here too. Space is the keyboard
                // equivalent; both feed the same set.
                if NSEvent.modifierFlags.contains(.command) {
                    onToggleMark()
                    return
                }
                onSelect()
                if NSApp.currentEvent?.clickCount == 2 {
                    appState.open(item)
                }
            }
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
            .accessibilityAction(
                named: isShowingFull ? "Show less" : "Show full message"
            ) { onToggleFull() }
            .accessibilityAction(named: isMarked ? "Unmark" : "Mark for grouping") {
                onToggleMark()
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                marker
                Image(systemName: display.systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                // Selection is what opens a row: one line is enough to tell
                // items apart, never enough to act on one, and opening every
                // row at once would just be a wall of text.
                VStack(alignment: .leading, spacing: 2) {
                    ExpandingText(
                        text: item.title, size: 13,
                        weight: item.highSignal ? .semibold : .regular,
                        expandedLines: RowExpansion.titleLines,
                        isExpanded: isSelected, isFull: isShowingFull,
                        animation: expansion)
                    if let secondary, !contextReplacesBody {
                        ExpandingText(
                            text: secondary, size: 12,
                            expandedLines: RowExpansion.bodyLines,
                            isExpanded: isSelected, isFull: isShowingFull,
                            animation: expansion)
                            .foregroundStyle(.secondary)
                    }
                    if showsTopicChip { topicChip }
                    if isShowingFull {
                        RowContextView(phase: contextPhase)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 4)
                // The quick actions used to sit here, beside the text —
                // on this panel's fixed width that meant every hover
                // squeezed the title down to whatever the five buttons
                // didn't want. They drop to their own line below instead,
                // so hovering never costs the text any width at all.
                if !isHovering { timeOrPin }
            }
            if isHovering { actionsRow }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(background)
    }

    /// The unseen dot — and, on hover, the checkbox that marks this row for
    /// a bulk verb.
    ///
    /// Marking had no visible affordance in the first build: it was Space and
    /// nothing else, so the first person to look for multi-select did not
    /// find it. A checkbox appearing under the cursor in a column that is
    /// already there costs no layout and makes the gesture discoverable the
    /// way everything else in this row is — by hovering it.
    @ViewBuilder private var marker: some View {
        Group {
            if isMarked || isHovering {
                MarkBox(isMarked: isMarked, size: 13)
            } else {
                Circle()
                    .fill(item.isSeen ? .clear : Color.accentColor)
                    .frame(width: 6, height: 6)
            }
        }
        // One fixed column whatever is in it, so the title never shifts
        // sideways as the cursor crosses the row.
        .frame(width: 14, height: 14)
        .padding(.top, 2)
        // The box is 13pt; the target is not. Growing the hit area past the
        // glyph costs no layout and stops a bulk pass from being a run of
        // precision clicks.
        .contentShape(.rect.inset(by: -5))
        .onTapGesture { onToggleMark() }
        .help(isMarked ? "Marked (Space, or ⌘-click)" : "Mark (Space, or ⌘-click)")
        .accessibilityHidden(true)
    }

    private var topicChip: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 9))
            Text("In a topic")
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(.quaternary))
        .accessibilityLabel("In a topic")
    }

    private var timeOrPin: some View {
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

    private var actionsRow: some View {
        HStack(spacing: 1) {
            Spacer(minLength: 0)
            // First, so adding it left the four triage verbs and the pin
            // exactly where they already were in this right-aligned stack.
            actionButton(
                isShowingFull
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                key: "D",
                isShowingFull
                    ? "Show less (D)" : "Show the whole message (D)",
                isShowingFull ? "Show less" : "Show full message"
            ) { onToggleFull() }
            actionButton(
                "arrow.up.forward.app", key: "⏎", "Open (⏎)", "Open"
            ) {
                appState.open(item)
            }
            actionButton(
                "checkmark.circle", key: "E",
                appState.canComplete(item)
                    ? "Dismiss — does not complete it (E)" : "Done (E)",
                appState.canComplete(item) ? "Dismiss" : "Mark done"
            ) {
                appState.markDone(item)
            }
            // Only sources with two end states — a to-do (seen vs done) and
            // mail (seen vs archived). The button is absent rather than
            // disabled: a greyed-out "complete" on every Slack mention would
            // be permanent clutter explaining itself to nobody.
            if appState.canComplete(item) {
                let verb = appState.completeVerb(for: item)
                actionButton(
                    item.sourceKind == "appleMail"
                        ? "archivebox" : "checkmark.circle.fill",
                    key: "C", verb.help, verb.button
                ) {
                    appState.completeTask(item)
                }
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
            actionButton(
                isMarked ? "checkmark.square.fill" : "square.stack.3d.up",
                key: "G",
                isTopicMember
                    ? "Move to another topic (G)"
                    : (isMarked
                        ? "Marked — press G to group" : "Group this (G)"),
                isTopicMember ? "Move to another topic" : "Group"
            ) { onGroup() }
        }
        .font(.system(size: 14))
        .buttonStyle(.borderless)
        .transition(.opacity)
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
            HStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                KeyCap(key)
            }
            // Icon-only buttons need an explicit frame — the bare glyph's
            // bounds make a fiddly ~14pt hit target.
            .padding(.horizontal, 2)
            .frame(height: 22)
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
        Button(appState.canComplete(item) ? "Dismiss" : "Mark Done") {
            appState.markDone(item)
        }
        if appState.canComplete(item) {
            Button(appState.completeVerb(for: item).menu) {
                appState.completeTask(item)
            }
        }
        Menu("Snooze") {
            ForEach(SnoozePreset.allCases) { preset in
                Button("\(preset.title) (\(preset.detail))") {
                    appState.snooze(item, until: preset.date())
                }
            }
            Divider()
            Button("Pick Date…") { snoozeTargetUID = item.uid }
        }
        Button(
            isShowingFull ? "Show Less" : "Show Full Message"
        ) { onToggleFull() }
        Button(item.isSeen ? "Mark as Unread" : "Mark as Read") {
            appState.toggleSeen(item)
        }
        Button(item.isPinned ? "Unpin" : "Pin") { appState.togglePin(item) }
        Divider()
        Button(isMarked ? "Unmark" : "Mark for Grouping") { onToggleMark() }
        Button(isTopicMember ? "Move to Another Topic…" : "Group…") {
            onGroup()
        }
        if isTopicMember {
            Button("Remove from Topic") { appState.removeFromTopic([item]) }
        }
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

    /// The same curve the rest of the queue moves on. When a dismissal
    /// moves the selection, the row leaving, the rows closing the gap, the
    /// scroll and this opening all run as one gesture — see `PanelMotion`.
    private var expansion: Animation? {
        PanelMotion.queue(reduceMotion: reduceMotion)
    }

    /// `isFullyExpanded` only means anything on the row that holds the
    /// selection — an unselected row is on its one line whatever the panel
    /// last had open, and the hover actions and context menu read this so
    /// they never offer "Show less" on a row that is showing one line.
    private var isShowingFull: Bool { isSelected && isFullyExpanded }

    /// The context request for *this* row — `AppState` holds one phase for
    /// the one row that can be fully expanded, and the uid check keeps a
    /// stale answer from painting a row the selection has since moved to.
    private var contextPhase: RowContextPhase {
        guard isShowingFull, appState.rowContextUID == item.uid else {
            return .idle
        }
        return appState.rowContext
    }

    /// A loaded focus message (a Slack thread) *is* the row's body — showing
    /// the body too would print the same text twice, once plain and once
    /// highlighted inside the fan.
    private var contextReplacesBody: Bool {
        guard isShowingFull, case .loaded(let context) = contextPhase else {
            return false
        }
        return context.replacesBody
            && context.messages.contains(where: \.isFocus)
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
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .monospacedDigit()
            // Every other cap is a single glyph; "⌘P" is two, and the trailing
            // action stack was squeezing it down to a lone ellipsis. A cap is
            // useless if it can't show its key.
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.quaternary))
            .accessibilityHidden(true)
    }
}
