import AppKit
import SwiftData
import SwiftUI

/// The menu bar panel: filter bar → Pinned → active queue grouped by source
/// with sticky headers → collapsed Snoozed → footer (§5.1). Keyboard-first;
/// the mouse is optional everywhere.
@MainActor
struct PanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \Item.occurredAt, order: .reverse) private var items: [Item]
    @Query(sort: \SourceConfig.sortOrder)
    private var sourceConfigs: [SourceConfig]

    @State private var selectedUID: String?
    @State private var filterText = ""
    @State private var isFiltering = false
    @AppStorage("panel.showSnoozed") private var showSnoozed = false
    @State private var showArchive = false
    @State private var snoozeTargetUID: String?
    @State private var isRefreshing = false
    @FocusState private var focus: PanelFocus?

    var body: some View {
        VStack(spacing: 0) {
            if showArchive {
                ArchiveView(
                    items: archivedItems, index: index,
                    restore: { restoreFromArchive($0) },
                    onClose: { showArchive = false })
            } else {
                FilterBar(
                    sources: chipSources, counts: chipCounts,
                    totalCount: textFiltered(queued).count,
                    selection: sourceFilterBinding, filterText: $filterText,
                    isFiltering: $isFiltering, focus: $focus,
                    onClearFilter: { clearFilter() })
                Divider()
                queue
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 520)
        .background { commandShortcuts }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .list)
        .onKeyPress(phases: .down) { handleKey($0) }
        .onAppear {
            focus = .list
            if selectedUID == nil { selectedUID = visibleUIDs.first }
        }
        .onChange(of: visibleUIDs) { old, new in
            reconcileSelection(old: old, new: new)
        }
        .onChange(of: filterText) { _, new in
            if new.isEmpty && focus != .filter { isFiltering = false }
        }
    }

    // MARK: Queue

    @ViewBuilder private var queue: some View {
        if pinnedItems.isEmpty && activeItems.isEmpty && snoozedItems.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(
                        alignment: .leading, spacing: 0,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        if !pinnedItems.isEmpty {
                            Section {
                                rows(pinnedItems)
                            } header: {
                                PanelSectionHeader(
                                    title: "Pinned", systemImage: "pin.fill",
                                    count: pinnedItems.count)
                            }
                        }
                        ForEach(activeGroups) { group in
                            Section {
                                rows(group.items)
                            } header: {
                                PanelSectionHeader(
                                    title: group.source.name,
                                    systemImage: group.source.systemImage,
                                    count: group.items.count)
                            }
                        }
                        if !snoozedItems.isEmpty { snoozedSection }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .animation(
                        reduceMotion ? nil : .snappy(duration: 0.22),
                        value: visibleUIDs)
                }
                .onChange(of: selectedUID) { _, new in
                    guard let new else { return }
                    if reduceMotion {
                        proxy.scrollTo(new, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func rows(_ list: [Item]) -> some View {
        ForEach(list) { item in
            ItemRowView(
                item: item, display: index.display(for: item),
                isSelected: selectedUID == item.uid,
                snoozeTargetUID: $snoozeTargetUID,
                onSelect: {
                    selectedUID = item.uid
                    focus = .list
                })
                .id(item.uid)
                .transition(
                    .opacity.combined(with: .move(edge: .leading)))
        }
    }

    private var snoozedSection: some View {
        Section {
            if showSnoozed { rows(snoozedItems) }
        } header: {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    showSnoozed.toggle()
                }
            } label: {
                PanelSectionHeader(
                    title: "Snoozed", systemImage: "clock",
                    count: snoozedItems.count,
                    disclosureExpanded: showSnoozed)
            }
            .buttonStyle(.plain)
            .help(showSnoozed ? "Hide snoozed items" : "Show snoozed items")
            .accessibilityLabel(
                "Snoozed, ^[\(snoozedItems.count) item](inflect: true)")
            .accessibilityAddTraits(showSnoozed ? [.isSelected] : [])
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(
                systemName: isNarrowed
                    ? "line.3.horizontal.decrease" : "cup.and.saucer")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(isNarrowed ? "Nothing matches" : "You're all caught up ☺")
                .font(.system(size: 13, weight: .medium))
            if isNarrowed {
                Button("Clear Filters") { clearAllFilters() }
                    .font(.system(size: 11))
                    .help("Show every source and clear the text filter")
            } else if let date = lastRefresh {
                Text("Last refreshed \(PanelFormat.relative(date)) ago")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(PanelFormat.full(date))
            } else {
                Text("Waiting for the first sync…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .multilineTextAlignment(.center)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                refresh()
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isRefreshing)
            .help("Refresh all sources (⌘R)")
            .accessibilityLabel("Refresh all sources")

            HStack(spacing: 3) {
                ForEach(statusSources) { source in
                    SourceStatusDot(
                        display: source, status: appState.statuses[source.id])
                }
            }

            if !appState.undoStack.isEmpty {
                Button {
                    appState.undoDone()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Undo last done (⌘Z)")
                .accessibilityLabel("Undo last done")
            }

            Spacer()

            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    showArchive.toggle()
                }
            } label: {
                Image(
                    systemName: showArchive
                        ? "archivebox.fill" : "archivebox")
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help(
                showArchive
                    ? "Back to the queue"
                    : "Archive — done items, last 90 days (⇧⌘A)")
            .accessibilityLabel(showArchive ? "Back to the queue" : "Archive")

            Button {
                openWindow(id: "main")
                NSApp.activate()
                dismiss()
            } label: {
                Image(systemName: "macwindow")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Open as Window (⌘0)")
            .accessibilityLabel("Open as window")

            SettingsLink { Image(systemName: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit Inbox & Chill (⌘Q)")
            .accessibilityLabel("Quit Inbox & Chill")
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// ⌘-modified commands. Real `keyboardShortcut` buttons rather than
    /// `onKeyPress` cases, because the Edit menu would otherwise swallow
    /// ⌘Z/⌘C before the panel ever sees them. Zero-sized on purpose.
    private var commandShortcuts: some View {
        Group {
            Button("Open and Mark Done") { openSelected(andDone: true) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Toggle Pin") { pinSelected() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Copy") { copySelected() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(focus == .filter)
            Button("Undo Done") { appState.undoDone() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(focus == .filter)
            Button("Find") {
                isFiltering = true
                focus = .filter
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Keyboard

    /// Plain keys only; ⌘-combos live in `commandShortcuts`.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.subtracting(.shift).isEmpty else {
            return .ignored
        }
        let character = press.key.character

        if character == KeyEquivalent.escape.character {
            if snoozeTargetUID != nil {
                snoozeTargetUID = nil
            } else if isFiltering || !filterText.isEmpty {
                clearFilter()
            } else if showArchive {
                showArchive = false
            } else {
                dismiss()
            }
            return .handled
        }
        // Archive mode has no visible queue selection; only Esc (handled
        // above) should reach past it.
        if showArchive { return .ignored }
        if character == KeyEquivalent.upArrow.character {
            moveSelection(-1)
            return .handled
        }
        if character == KeyEquivalent.downArrow.character {
            moveSelection(1)
            return .handled
        }
        if character == KeyEquivalent.return.character {
            openSelected(andDone: false)
            return .handled
        }
        // While the filter field owns focus it handles its own typing.
        guard focus != .filter else { return .ignored }

        if character == KeyEquivalent.delete.character {
            guard !filterText.isEmpty else { return .ignored }
            filterText.removeLast()
            if filterText.isEmpty { isFiltering = false }
            return .handled
        }
        // Bare E/S are commands only before a filter has begun; once typing
        // has started, every printable character — including e/s — extends
        // the filter instead (so e.g. "slack" can be typed).
        switch character {
        case "e", "E" where filterText.isEmpty && !isFiltering:
            doneSelected()
            return .handled
        case "s", "S" where filterText.isEmpty && !isFiltering:
            if selectedItem != nil { snoozeTargetUID = selectedUID }
            return .handled
        default:
            guard character.isLetter || character.isNumber
                || character.isPunctuation || character == " "
            else { return .ignored }
            isFiltering = true
            filterText.append(character)
            return .handled
        }
    }

    private func moveSelection(_ delta: Int) {
        let uids = visibleUIDs
        guard !uids.isEmpty else { return }
        guard let current = selectedUID,
            let position = uids.firstIndex(of: current)
        else {
            selectedUID = delta > 0 ? uids.first : uids.last
            return
        }
        let next = min(max(position + delta, 0), uids.count - 1)
        selectedUID = uids[next]
    }

    /// Keeps the selection meaningful when a row leaves the queue (done,
    /// snoozed, filtered away): step to the next surviving row.
    private func reconcileSelection(old: [String], new: [String]) {
        guard let current = selectedUID else {
            selectedUID = new.first
            return
        }
        guard !new.contains(current) else { return }
        guard let position = old.firstIndex(of: current) else {
            selectedUID = new.first
            return
        }
        selectedUID =
            old[(position + 1)...].first { new.contains($0) }
            ?? old[..<position].last { new.contains($0) }
            ?? new.first
    }

    // MARK: Actions

    private func openSelected(andDone: Bool) {
        guard let item = selectedItem else { return }
        appState.open(item)
        if andDone { appState.markDone(item) }
    }

    private func doneSelected() {
        guard let item = selectedItem else { return }
        appState.markDone(item)
    }

    private func pinSelected() {
        guard let item = selectedItem else { return }
        appState.togglePin(item)
    }

    private func copySelected() {
        guard let item = selectedItem else { return }
        PanelPasteboard.copy(title: item.title, url: item.url)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await appState.engine.refreshNow()
            isRefreshing = false
        }
    }

    private func restoreFromArchive(_ item: Item) {
        appState.restore(uid: item.uid)
    }

    private func clearFilter() {
        filterText = ""
        isFiltering = false
        focus = .list
    }

    private func clearAllFilters() {
        appState.selectedSourceFilter = nil
        clearFilter()
    }

    // MARK: Derived state

    private var index: SourceIndex {
        SourceIndex(configs: sourceConfigs, items: items)
    }

    private var sourceFilterBinding: Binding<String?> {
        Binding(
            get: { appState.selectedSourceFilter },
            set: { newValue in
                appState.selectedSourceFilter = newValue
                focus = .list
            })
    }

    /// Everything still in the queue: pinned, active, or snoozed.
    private var queued: [Item] { items.filter { !$0.isDone } }

    private var pinnedItems: [Item] { scoped(queued.filter(\.isPinned)) }

    private var activeItems: [Item] {
        scoped(queued.filter { $0.isActive && !$0.isPinned })
    }

    private var snoozedItems: [Item] {
        scoped(queued.filter { $0.isSnoozed && !$0.isPinned })
    }

    private var activeGroups: [SourceGroup] {
        let grouped = Dictionary(grouping: activeItems, by: \.sourceID)
        return index.ordered(ids: grouped.keys).compactMap { source in
            guard let group = grouped[source.id], !group.isEmpty else {
                return nil
            }
            return SourceGroup(source: source, items: group)
        }
    }

    /// Keyboard traversal order: exactly what is on screen, top to bottom.
    private var visibleUIDs: [String] {
        pinnedItems.map(\.uid) + activeGroups.flatMap { $0.items.map(\.uid) }
            + (showSnoozed ? snoozedItems.map(\.uid) : [])
    }

    private var selectedItem: Item? {
        guard let selectedUID else { return nil }
        return items.first { $0.uid == selectedUID }
    }

    /// One chip per source with queued items, plus the current filter even if
    /// its source just emptied out (so the scope never gets stuck invisible).
    private var chipSources: [SourceDisplay] {
        var ids = Set(textFiltered(queued).map(\.sourceID))
        if let filter = appState.selectedSourceFilter { ids.insert(filter) }
        return index.ordered(ids: ids)
    }

    private var chipCounts: [String: Int] {
        textFiltered(queued).reduce(into: [:]) { counts, item in
            counts[item.sourceID, default: 0] += 1
        }
    }

    private var statusSources: [SourceDisplay] {
        index.ordered(
            ids: Set(sourceConfigs.map(\.id))
                .union(appState.statuses.keys.filter { !$0.isEmpty }))
    }

    private var archivedItems: [Item] {
        let cutoff = TriagePolicy.purgeCutoff()
        return items
            .compactMap { item -> (Item, Date)? in
                guard let doneAt = item.doneAt, doneAt >= cutoff else {
                    return nil
                }
                return (item, doneAt)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    private var lastRefresh: Date? {
        appState.statuses.values
            .compactMap { status -> Date? in
                if case .ok(let date) = status { return date }
                return nil
            }
            .max()
    }

    private var isNarrowed: Bool {
        appState.selectedSourceFilter != nil
            || !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Filtering

    private func scoped(_ list: [Item]) -> [Item] {
        var result = textFiltered(list)
        if let filter = appState.selectedSourceFilter {
            result = result.filter { $0.sourceID == filter }
        }
        return result
    }

    private func textFiltered(_ list: [Item]) -> [Item] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return list }
        let sources = index
        return list.filter { item in
            [
                item.title, item.snippet ?? "", item.actorName ?? "",
                sources.display(for: item).name,
            ]
            .contains { $0.lowercased().contains(query) }
        }
    }
}

/// Sticky section header: glyph, title, count, optional disclosure chevron.
struct PanelSectionHeader: View {
    let title: String
    let systemImage: String
    let count: Int
    var disclosureExpanded: Bool?

    var body: some View {
        HStack(spacing: 4) {
            if let disclosureExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(disclosureExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: systemImage)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar)
        .contentShape(.rect)
    }
}
