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
    @Environment(\.openSettings) private var openSettings
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
    /// Which footer control the mouse is over, if any — see `PanelHint`.
    @State private var hoveredHint: PanelHint?
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
        .frame(width: 420, height: 560)
        .background { commandShortcuts }
        .background { PanelKeyboardFocus() }
        .background { PanelKeyCapture(handle: handle) }
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
        .onChange(of: selectedUID, initial: true) { _, _ in
            // Focus is what marks an item read — arrowing onto a row counts,
            // and so does the auto-selection when the panel opens, because
            // that row is the one you are looking at.
            markSelectedSeen()
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
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(isNarrowed ? "Nothing matches" : "You're all caught up ☺")
                .font(.system(size: 14, weight: .medium))
            if isNarrowed {
                Button("Clear Filters") { clearAllFilters() }
                    .font(.system(size: 12))
                    .help("Show every source and clear the text filter")
            } else if let date = lastRefresh {
                Text("Last refreshed \(PanelFormat.relative(date)) ago")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help(PanelFormat.full(date))
            } else {
                Text("Waiting for the first sync…")
                    .font(.system(size: 12))
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
        HStack(spacing: 8) {
            Button {
                refresh()
            } label: {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 24)
                } else {
                    footerIcon("arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isRefreshing)
            // No `isRefreshing` variant: a disabled control takes no hover
            // events, so that string could never be read.
            .panelHint(
                "Refresh all sources", shortcut: "⌘R", hovered: $hoveredHint)

            HStack(spacing: 1) {
                ForEach(statusSources) { source in
                    SourceStatusDot(
                        display: source, status: appState.statuses[source.id],
                        hoveredHint: $hoveredHint)
                }
            }

            if !appState.undoStack.isEmpty {
                Button {
                    appState.undoDone()
                } label: {
                    footerIcon("arrow.uturn.backward")
                }
                .panelHint(
                    "Undo last done", shortcut: "⌘Z", hovered: $hoveredHint)
            }

            Spacer()

            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    showArchive.toggle()
                }
            } label: {
                footerIcon(showArchive ? "archivebox.fill" : "archivebox")
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .panelHint(
                showArchive
                    ? "Back to the queue"
                    : "Archive — done items, last 90 days",
                shortcut: "⇧⌘A", hovered: $hoveredHint)

            Button {
                openWindow(id: "main")
                WindowActivation.focusMainWindow()
                dismiss()
            } label: {
                footerIcon("macwindow")
            }
            .keyboardShortcut("0", modifiers: .command)
            .panelHint(
                "Open the queue in a window", shortcut: "⌘0",
                hovered: $hoveredHint)

            Button {
                openSettings()
                WindowActivation.focusSettings()
                dismiss()
            } label: {
                footerIcon("gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .panelHint(
                "Settings — sources and general", shortcut: "⌘,",
                hovered: $hoveredHint)

            Button {
                NSApp.terminate(nil)
            } label: {
                footerIcon("power")
            }
            .keyboardShortcut("q", modifiers: .command)
            .panelHint(
                "Quit Inbox & Chill", shortcut: "⌘Q", hovered: $hoveredHint)
        }
        .font(.system(size: 14))
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .panelHintHost(hovered: hoveredHint)
    }

    /// Footer buttons are icon-only; without an explicit frame their hit
    /// target is just the glyph's bounds (~14pt). Pad every one out to a
    /// clickable 26×24.
    private func footerIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .frame(width: 26, height: 24)
            .contentShape(.rect)
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
    ///
    /// Reached from two directions — the `PanelKeyCapture` monitor (the path
    /// that actually works when the panel opens cold) and SwiftUI's
    /// `onKeyPress` (a fallback for when no monitor is installed). Both funnel
    /// through here so they can never disagree.
    ///
    /// Returns `true` when the press was consumed.
    private func handle(
        _ input: PanelKeyInput, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers.subtracting([.shift, .capsLock, .function, .numericPad])
            .isEmpty
        else { return false }

        if input == .escape {
            if snoozeTargetUID != nil {
                snoozeTargetUID = nil
            } else if isFiltering || !filterText.isEmpty {
                clearFilter()
            } else if showArchive {
                showArchive = false
            } else {
                dismiss()
            }
            return true
        }
        // Archive mode has no visible queue selection; only Esc (handled
        // above) should reach past it.
        if showArchive { return false }

        switch input {
        case .up:
            moveSelection(-1)
            return true
        case .down:
            moveSelection(1)
            return true
        // ←/→ step through the source filter chips. "All" is part of the
        // cycle rather than a separate mode, so repeated presses always get
        // you back to an unfiltered queue. While the filter field has focus
        // they belong to the text cursor instead.
        case .left where focus != .filter:
            moveFilter(-1)
            return true
        case .right where focus != .filter:
            moveFilter(1)
            return true
        case .enter:
            openSelected(andDone: false)
            return true
        default:
            break
        }

        // While the filter field owns focus it handles its own typing.
        guard focus != .filter else { return false }

        if input == .backspace {
            guard !filterText.isEmpty else { return false }
            filterText.removeLast()
            if filterText.isEmpty { isFiltering = false }
            return true
        }

        guard case .character(let character) = input else { return false }

        // Bare E/S are commands only before a filter has begun; once typing
        // has started, every printable character — including e/s — extends
        // the filter instead (so e.g. "slack" can be typed).
        switch character {
        // The `where` must repeat per pattern — a bare "e" pattern would
        // match unconditionally and mark items done mid-filter.
        case "e" where filterText.isEmpty && !isFiltering,
            "E" where filterText.isEmpty && !isFiltering:
            doneSelected()
            return true
        case "s" where filterText.isEmpty && !isFiltering,
            "S" where filterText.isEmpty && !isFiltering:
            if selectedItem != nil { snoozeTargetUID = selectedUID }
            return true
        default:
            guard character.isLetter || character.isNumber
                || character.isPunctuation || character == " "
            else { return false }
            isFiltering = true
            filterText.append(character)
            return true
        }
    }

    /// SwiftUI's path into `handle`, kept as a fallback for the case where no
    /// event monitor is installed.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let input = PanelKeyInput(press) else { return .ignored }
        let modifiers: NSEvent.ModifierFlags =
            press.modifiers.contains(.shift) ? .shift : []
        return handle(input, modifiers: modifiers) ? .handled : .ignored
    }

    /// Cycles `selectedSourceFilter` across `nil` (All) plus every chip.
    /// Clamped rather than wrapping: running off either end is a no-op, which
    /// keeps ←/← predictable instead of teleporting to the far side.
    private func moveFilter(_ delta: Int) {
        guard focus != .filter else { return }
        let options: [String?] = [nil] + chipSources.map { $0.id as String? }
        guard options.count > 1 else { return }
        let current = options.firstIndex(of: appState.selectedSourceFilter) ?? 0
        let next = min(max(current + delta, 0), options.count - 1)
        guard next != current else { return }
        appState.selectedSourceFilter = options[next]
    }

    private func markSelectedSeen() {
        guard let item = selectedItem, !item.isSeen else { return }
        appState.markSeen(item)
    }

    private func moveSelection(_ delta: Int) {
        guard
            let next = PanelSelection.next(
                from: selectedUID, in: visibleUIDs, by: delta)
        else { return }
        selectedUID = next
        focus = .list
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
        HStack(spacing: 5) {
            if let disclosureExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(disclosureExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
            Text("\(count)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .contentShape(.rect)
    }
}


/// Gives the panel keyboard focus as soon as it opens.
///
/// `MenuBarExtra(.window)` presents its content in a window that isn't made
/// key on its own, and a SwiftUI `.focusable()` view inside it doesn't become
/// first responder until something is clicked. Until then `onKeyPress` never
/// fires at all — so for a keyboard-first user the panel looks simply broken:
/// arrows, E, S and ⏎ all do nothing until they click a row first.
///
/// Making the hosting window key on appear is what lets the focus SwiftUI
/// already tracks (`@FocusState`) actually receive events.
struct PanelKeyboardFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusNudger() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FocusNudger: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Deferred: at viewDidMoveToWindow the window isn't yet on screen,
            // and makeKey on an unmapped window is dropped silently.
            DispatchQueue.main.async {
                guard window.isVisible else { return }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
