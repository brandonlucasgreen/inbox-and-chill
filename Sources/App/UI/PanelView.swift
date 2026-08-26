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

    /// The queue only — done items are the archive's business, and there
    /// are two orders of magnitude more of them. Fetching them here meant
    /// every panel render walked the entire 90-day archive to find the
    /// handful of rows on screen.
    @Query(
        filter: #Predicate<Item> { $0.doneAt == nil },
        sort: \Item.occurredAt, order: .reverse)
    private var items: [Item]
    @Query(sort: \SourceConfig.sortOrder)
    private var sourceConfigs: [SourceConfig]

    @State private var selectedUID: String?
    /// Whether the selected row is showing its whole message (D). One flag
    /// for the panel, not one per row: only the selected row can be open at
    /// all, and a row that loses the selection closes back to a line.
    @State private var isFullyExpanded = false
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
        // Once per body pass, not once per read and not once per row.
        let queue = queue
        VStack(spacing: 0) {
            if showArchive {
                ArchiveView(
                    index: queue.index,
                    restore: { restoreFromArchive($0) },
                    complete: { appState.completeTask($0) },
                    open: { appState.open($0) },
                    onClose: { showArchive = false })
            } else {
                FilterBar(
                    sources: queue.chips, counts: queue.chipCounts,
                    totalCount: queue.matchCount,
                    selection: sourceFilterBinding, filterText: $filterText,
                    isFiltering: $isFiltering, focus: $focus,
                    onClearFilter: { clearFilter() })
                Divider()
                queueList(queue)
            }
            Divider()
            LicenseNotice()
            openProblemNotice
            footer(queue.index)
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
            if selectedUID == nil { select(queue.visibleUIDs.first) }
        }
        .onChange(of: queue.visibleUIDs) { old, new in
            reconcileSelection(old: old, new: new)
        }
        .task(id: selectedUID) {
            // Focus is what marks an item read — arrowing onto a row counts,
            // and so does the auto-selection when the panel opens, because
            // that row is the one you are looking at.
            //
            // Deliberately delayed. Marking seen writes to the store, and when
            // a dismissal moves the selection that write used to land in the
            // middle of the row-removal animation and stutter it. Waiting also
            // means arrowing straight past a row no longer counts as reading
            // it, which is the better reading of "seen" anyway.
            guard let item = selectedItem, !item.isSeen else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            appState.markSeen(item)
        }
        .onChange(of: filterText) { _, new in
            if new.isEmpty && focus != .filter { isFiltering = false }
        }
    }

    // MARK: Queue

    @ViewBuilder private func queueList(_ queue: PanelQueue) -> some View {
        if queue.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(
                        alignment: .leading, spacing: 0,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        if !queue.pinned.isEmpty {
                            Section {
                                rows(queue.pinned, index: queue.index)
                            } header: {
                                PanelSectionHeader(
                                    title: "Pinned", systemImage: "pin.fill",
                                    count: queue.pinned.count)
                            }
                        }
                        ForEach(queue.groups) { group in
                            Section {
                                rows(group.items, index: queue.index)
                            } header: {
                                PanelSectionHeader(
                                    title: group.source.name,
                                    systemImage: group.source.systemImage,
                                    count: group.items.count)
                            }
                        }
                        if !queue.snoozed.isEmpty { snoozedSection(queue) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .animation(
                        PanelMotion.queue(reduceMotion: reduceMotion),
                        value: queue.visibleUIDs)
                    // Selection opens the focused row and closes the one it
                    // left (`ExpandingText`). Animating it at the list level
                    // too is what makes every row below the pair slide with
                    // them, in the same transaction as the scroll below.
                    .animation(
                        PanelMotion.queue(reduceMotion: reduceMotion),
                        value: selectedUID)
                    .animation(
                        PanelMotion.queue(reduceMotion: reduceMotion),
                        value: isFullyExpanded)
                    // The context section fades/grows in on the same curve
                    // as everything else the queue does.
                    .animation(
                        PanelMotion.queue(reduceMotion: reduceMotion),
                        value: appState.rowContext)
                }
                .onChange(of: selectedUID) { _, new in
                    guard let new else { return }
                    // Same curve and duration as the row collapse above: when
                    // a dismissal moves the selection, both happen at once,
                    // and they have to be one gesture rather than two.
                    withAnimation(
                        PanelMotion.queue(reduceMotion: reduceMotion)
                    ) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
                // A message long enough to be worth D is often longer than
                // the panel, so the row is anchored to the top rather than
                // centred: the text has to start where you can read it, and
                // scrolling down from there is the rest of the message.
                // Closing it puts the row back where the selection lives.
                .onChange(of: isFullyExpanded) { _, isFull in
                    guard let selectedUID else { return }
                    withAnimation(
                        PanelMotion.queue(reduceMotion: reduceMotion)
                    ) {
                        proxy.scrollTo(
                            selectedUID, anchor: isFull ? .top : .center)
                    }
                }
                // Context arrives after the expansion has already anchored,
                // and it grows the row — so the anchor runs a second time,
                // or the new content pushes the row's tail off-screen.
                .onChange(of: appState.rowContext) { _, phase in
                    guard isFullyExpanded, let selectedUID,
                        case .loaded = phase
                    else { return }
                    withAnimation(
                        PanelMotion.queue(reduceMotion: reduceMotion)
                    ) {
                        proxy.scrollTo(selectedUID, anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder private func rows(
        _ list: [Item], index: SourceIndex
    ) -> some View {
        ForEach(list) { item in
            ItemRowView(
                item: item, display: index.display(for: item),
                isSelected: selectedUID == item.uid,
                isFullyExpanded: isFullyExpanded,
                snoozeTargetUID: $snoozeTargetUID,
                onSelect: {
                    select(item.uid)
                    focus = .list
                },
                onToggleFull: { toggleFull(item.uid) })
                .id(item.uid)
                .transition(PanelMotion.row)
        }
    }

    private func snoozedSection(_ queue: PanelQueue) -> some View {
        Section {
            if showSnoozed { rows(queue.snoozed, index: queue.index) }
        } header: {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    showSnoozed.toggle()
                }
            } label: {
                PanelSectionHeader(
                    title: "Snoozed", systemImage: "clock",
                    count: queue.snoozed.count,
                    disclosureExpanded: showSnoozed)
            }
            .buttonStyle(.plain)
            .help(showSnoozed ? "Hide snoozed items" : "Show snoozed items")
            .accessibilityLabel(
                "Snoozed, ^[\(queue.snoozed.count) item](inflect: true)")
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
                Text(PanelFormat.refreshed(date))
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

    /// Why the last ⏎ didn't land where the row pointed.
    ///
    /// The panel is where the user pressed the key, so it is where the answer
    /// belongs — Settings is too far away to connect to a keypress. Shown
    /// only for problems the user can act on; a session whose window has
    /// simply closed falls back to the folder and says nothing.
    @ViewBuilder
    private var openProblemNotice: some View {
        if let problem = appState.openProblem {
            HStack(alignment: .top, spacing: 8) {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Open Settings") {
                    NSWorkspace.shared.open(ClaudeSessionTarget.systemSettingsAutomationURL)
                    appState.openProblem = nil
                }
                .font(.system(size: 11))
                Button {
                    appState.openProblem = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.red.opacity(0.08))
            Divider()
        }
    }

    private func footer(_ index: SourceIndex) -> some View {
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
                ForEach(statusSources(index)) { source in
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
            // Esc peels back one layer at a time, and a row showing its
            // whole message is the layer most recently added — closing the
            // panel out from under it would lose the filter and the
            // selection to undo one press of D.
            } else if isFullyExpanded {
                isFullyExpanded = false
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
        case "u" where filterText.isEmpty && !isFiltering,
            "U" where filterText.isEmpty && !isFiltering:
            unreadSelected()
            return true
        case "d" where filterText.isEmpty && !isFiltering,
            "D" where filterText.isEmpty && !isFiltering:
            expandSelected()
            return true
        // Complete, as distinct from dismiss. Only to-do sources can, and the
        // key says so rather than doing nothing when they can't — a silent
        // no-op reads as a broken shortcut.
        case "c" where filterText.isEmpty && !isFiltering,
            "C" where filterText.isEmpty && !isFiltering:
            completeSelected()
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
        let options: [String?] = [nil] + queue.chips.map { $0.id as String? }
        guard options.count > 1 else { return }
        let current = options.firstIndex(of: appState.selectedSourceFilter) ?? 0
        let next = min(max(current + delta, 0), options.count - 1)
        guard next != current else { return }
        appState.selectedSourceFilter = options[next]
    }

    /// Flips the selected row between read and unread (`U`).
    private func unreadSelected() {
        guard let item = selectedItem else { return }
        appState.toggleSeen(item)
    }

    private func moveSelection(_ delta: Int) {
        guard
            let next = PanelSelection.next(
                from: selectedUID, in: queue.visibleUIDs, by: delta)
        else { return }
        select(next)
        focus = .list
    }

    /// The one way the selection moves, because moving it always closes a
    /// full expansion (D). Remembering the expansion per row instead would
    /// leave a screenful of full-height rows behind after a few presses, in
    /// a panel whose whole job is to fit the queue on one screen.
    ///
    /// Reset here rather than in an `onChange`: a click on a row's D button
    /// selects and expands in the same event, and an `onChange` observer
    /// would run after both and close what the click just opened.
    private func select(_ uid: String?) {
        guard uid != selectedUID else { return }
        selectedUID = uid
        isFullyExpanded = false
        appState.clearContext()
    }

    /// D, and the row's own expand button. Takes the selection first when
    /// the click landed on some other row, so the thing that opens is the
    /// thing that was clicked.
    private func toggleFull(_ uid: String) {
        if uid != selectedUID {
            select(uid)
            focus = .list
        }
        isFullyExpanded.toggle()
        // The context request lives and dies with the expansion: opening
        // starts it (or replays the cache), closing cancels it so a late
        // answer can't grow a row that's back to one line.
        if isFullyExpanded, let item = selectedItem {
            appState.fetchContext(for: item)
        } else {
            appState.clearContext()
        }
    }

    /// D against whatever holds the selection — nothing to open on an
    /// empty queue.
    private func expandSelected() {
        guard let selectedUID else { return }
        toggleFull(selectedUID)
    }

    /// Keeps the selection meaningful when a row leaves the queue (done,
    /// snoozed, filtered away): step to the next surviving row.
    private func reconcileSelection(old: [String], new: [String]) {
        guard let current = selectedUID else {
            select(new.first)
            return
        }
        guard !new.contains(current) else { return }
        guard let position = old.firstIndex(of: current) else {
            select(new.first)
            return
        }
        select(
            old[(position + 1)...].first { new.contains($0) }
                ?? old[..<position].last { new.contains($0) }
                ?? new.first)
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

    /// `C` — finish the task in its source.
    ///
    /// `appState.completeTask` is what refuses a non-task row, and it does so
    /// out loud: it sets `openProblem`, which the panel already surfaces. That
    /// keeps the "which sources can do this" answer in one place instead of
    /// duplicating the capability check here.
    private func completeSelected() {
        guard let item = selectedItem else { return }
        appState.completeTask(item)
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

    /// The whole visible layout, derived in one pass. Read once per body
    /// evaluation and passed down — never re-read inside a loop.
    private var queue: PanelQueue {
        PanelQueue(
            queued: items, configs: sourceConfigs,
            sourceFilter: appState.selectedSourceFilter,
            filterText: filterText, showSnoozed: showSnoozed)
    }

    private var sourceFilterBinding: Binding<String?> {
        Binding(
            get: { appState.selectedSourceFilter },
            set: { newValue in
                appState.selectedSourceFilter = newValue
                focus = .list
            })
    }

    private var selectedItem: Item? {
        guard let selectedUID else { return nil }
        return items.first { $0.uid == selectedUID }
    }

    private func statusSources(_ index: SourceIndex) -> [SourceDisplay] {
        index.ordered(
            ids: Set(sourceConfigs.map(\.id))
                .union(appState.statuses.keys.filter { !$0.isEmpty }))
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
