import SwiftUI

/// The header row for a topic: disclosure triangle, name, the sources it
/// spans, and the same triage verbs a row has.
///
/// It is a *row*, not a section header, and that is the load-bearing choice.
/// `E` on it dismisses every member — if it only folded four rows up and left
/// them behind, there would be no reason to have built any of this. So it
/// carries the same hover actions, the same context menu and the same
/// selection chrome as `ItemRowView`, and the panel's key handler routes the
/// same letters here.
struct TopicRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let topic: TopicGroup
    let isSelected: Bool
    let isOpen: Bool
    @Binding var snoozeTargetUID: String?
    var onSelect: () -> Void
    var onToggleOpen: () -> Void
    var onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        row
            .contentShape(.rect)
            .onTapGesture(count: 2) { onToggleOpen() }
            .onTapGesture { onSelect() }
            .onHover { isHovering = $0 }
            .contextMenu { contextMenu }
            .popover(isPresented: snoozePopoverBinding, arrowEdge: .trailing) {
                SnoozePopover(title: topic.name) { date in
                    snoozeTargetUID = nil
                    appState.snooze(
                        topic.members, until: date, topicName: topic.name)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityAction(named: isOpen ? "Collapse" : "Expand") {
                onToggleOpen()
            }
            .accessibilityAction(named: "Dismiss All") { dismissAll() }
            .accessibilityAction(named: "Edit Topic") { onEdit() }
    }

    // MARK: Layout

    private var row: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(topic.isSeen ? .clear : Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    ExpandingText(
                        text: topic.name, size: 13,
                        weight: topic.highSignal ? .semibold : .medium,
                        expandedLines: RowExpansion.titleLines,
                        isExpanded: isSelected,
                        animation: PanelMotion.queue(reduceMotion: reduceMotion))
                    sourceChips
                }
                Spacer(minLength: 4)
                if !isHovering { countAndTime }
            }
            if isHovering { actionsRow }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(background)
    }

    /// How many source chips fit beside a name in a 420pt panel before they
    /// start clipping. Past this the rest become "+2" — a count is still an
    /// honest answer, and a chip cut in half is not.
    private static let visibleChips = 3

    /// Which sources are in here, which is the one fact a collapsed topic
    /// has that a single row does not.
    private var sourceChips: some View {
        HStack(spacing: 4) {
            ForEach(topic.sources.prefix(Self.visibleChips)) { source in
                HStack(spacing: 3) {
                    Image(systemName: source.systemImage)
                        .font(.system(size: 9))
                    Text(source.name)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(.quaternary))
            }
            if topic.sources.count > Self.visibleChips {
                Text("+\(topic.sources.count - Self.visibleChips)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .accessibilityHidden(true)
    }

    private var countAndTime: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(PanelFormat.relative(topic.newest))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack(spacing: 3) {
                if topic.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 9))
                }
                Text("\(topic.activeCount)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
        }
        .help(PanelFormat.full(topic.newest))
    }

    private var actionsRow: some View {
        HStack(spacing: 1) {
            Spacer(minLength: 0)
            actionButton(
                isOpen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                key: "D", isOpen ? "Collapse (D)" : "Show what's in it (D)",
                isOpen ? "Collapse" : "Expand"
            ) { onToggleOpen() }
            actionButton(
                "checkmark.circle", key: "E",
                "Dismiss all \(topic.activeCount) (E)", "Dismiss all"
            ) { dismissAll() }
            if appState.canCompleteAll(topic.members) {
                actionButton(
                    "checkmark.circle.fill", key: "C",
                    "Complete all \(topic.activeCount) (C)", "Complete all"
                ) {
                    appState.completeTask(
                        topic.members, topicName: topic.name)
                }
            }
            SnoozeMenu(
                apply: {
                    appState.snooze(
                        topic.members, until: $0, topicName: topic.name)
                },
                pickDate: { snoozeTargetUID = topic.rowID })
            actionButton(
                topic.isPinned ? "pin.slash" : "pin", key: "⌘P",
                topic.isPinned ? "Unpin topic (⌘P)" : "Pin topic (⌘P)",
                topic.isPinned ? "Unpin" : "Pin"
            ) { appState.setPinned(topic.members, pinned: !topic.isPinned) }
            actionButton(
                "square.and.pencil", key: "G", "Edit topic (G)", "Edit topic"
            ) { onEdit() }
        }
        .font(.system(size: 14))
        .buttonStyle(.borderless)
        .transition(.opacity)
    }

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
            .padding(.horizontal, 2)
            .frame(height: 22)
            .contentShape(.rect)
        }
        .help(help)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder private var contextMenu: some View {
        Button(isOpen ? "Collapse" : "Show What's In It") { onToggleOpen() }
        Divider()
        Button("Dismiss All \(topic.activeCount)") { dismissAll() }
        if appState.canCompleteAll(topic.members) {
            Button("Complete All \(topic.activeCount)") {
                appState.completeTask(topic.members, topicName: topic.name)
            }
        }
        Menu("Snooze All") {
            ForEach(SnoozePreset.allCases) { preset in
                Button("\(preset.title) (\(preset.detail))") {
                    appState.snooze(
                        topic.members, until: preset.date(),
                        topicName: topic.name)
                }
            }
            Divider()
            Button("Pick Date…") { snoozeTargetUID = topic.rowID }
        }
        Button(topic.isPinned ? "Unpin Topic" : "Pin Topic") {
            appState.setPinned(topic.members, pinned: !topic.isPinned)
        }
        Divider()
        Button("Edit Topic…") { onEdit() }
        // Safe to offer without a confirmation: ungrouping dismisses nothing.
        // Every member goes back to its own source section intact.
        Button("Ungroup") { appState.deleteTopic(id: topic.id) }
    }

    // MARK: Derived

    private func dismissAll() {
        appState.markDone(topic.members, topicName: topic.name)
    }

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

    private var accessibilityLabel: String {
        var text = "Topic: \(topic.name), ^[\(topic.activeCount) item](inflect: true)"
        text += " from \(topic.sources.map(\.name).formatted(.list(type: .and)))"
        text += ", \(PanelFormat.relative(topic.newest)) ago"
        if topic.isPinned { text += ", pinned" }
        if !topic.isSeen { text += ", unseen" }
        return text
    }

    private var snoozePopoverBinding: Binding<Bool> {
        Binding(
            get: { snoozeTargetUID == topic.rowID },
            set: { if !$0 { snoozeTargetUID = nil } })
    }
}
