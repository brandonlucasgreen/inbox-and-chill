import AppKit
import SwiftData
import SwiftUI

/// The optional full triage window (§5.2): sidebar scopes on the left, the
/// same queue the panel shows as a sortable, multi-select `Table` on the
/// right. Drop it into a plain `WindowGroup(id: "main")` with
/// `.environment(AppState.self)` and `.modelContainer` already applied.
///
/// Every command here is also a menu item: the window publishes
/// `\.triageActions` (see `TriageActions`) and `MainWindowCommands` builds the
/// Queue menu and the View menu's scope switching from it.
@MainActor
struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \Item.occurredAt, order: .reverse) private var items: [Item]
    @Query(sort: \SourceConfig.sortOrder)
    private var sourceConfigs: [SourceConfig]

    /// Restored per scene (§5.3). Stored as `TriageScope.storageValue`.
    @SceneStorage("mainWindow.scope") private var scopeStorage = "all"
    @SceneStorage("mainWindow.sortKey") private var sortKeyStorage = "age"
    @SceneStorage("mainWindow.sortAscending") private var sortAscending = false

    @State private var selection: Set<PersistentIdentifier> = []
    @State private var sortOrder: [KeyPathComparator<Item>] = [
        KeyPathComparator(\Item.occurredAt, order: .reverse)
    ]
    @State private var searchText = ""
    @State private var isRefreshing = false
    /// Rows waiting on the "Pick Date…" popover — not necessarily the
    /// selection, since a right-click can target a single unselected row.
    @State private var snoozeTargetIDs: Set<PersistentIdentifier>?
    @State private var topicEditor: TopicEditorRequest?
    @Query(sort: \Topic.createdAt) private var allTopics: [Topic]
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .focusedSceneValue(\.triageActions, actions)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let sources = index
        let counts = scopeCounts
        return List(selection: scopeSelection) {
            Section {
                ForEach(TriageScope.fixed, id: \.self) { target in
                    scopeRow(target, in: sources, count: counts[target] ?? 0)
                }
            }
            Section("Sources") {
                ForEach(sidebarSources) { source in
                    scopeRow(
                        .source(source.id), in: sources,
                        count: counts[.source(source.id)] ?? 0)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 214, max: 320)
        .navigationTitle("Queue")
    }

    private func scopeRow(
        _ target: TriageScope, in sources: SourceIndex, count: Int
    ) -> some View {
        Label(
            target.title(in: sources),
            systemImage: target.systemImage(in: sources))
            .badge(count)
            .help(target.help)
            .tag(target)
    }

    // MARK: Detail

    private var detail: some View {
        // Built once here, not once per row. `index` walks every item, and
        // reading it inside the table's column builders (and `tooltip`) made
        // that walk happen for every visible row — invisible at ten items,
        // very visible at a thousand.
        let sources = index
        return table(sources)
            .navigationTitle(scope.title(in: sources))
            .navigationSubtitle(subtitle)
            .searchable(
                text: $searchText,
                prompt: Text("Search title, snippet, or person"))
            // macOS 15 search focus: keeps plain-key menu equivalents (E) from
            // eating characters typed into the search field.
            .searchFocused($isSearchFocused)
            .toolbar(id: "mainWindow") { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    LicenseNotice()
                    statusBar
                }
            }
    }

    private func table(_ index: SourceIndex) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Source", value: \.sourceKind) { item in
                let source = index.display(for: item)
                Label(source.name, systemImage: source.systemImage)
                    .help(source.name)
            }
            .width(min: 96, ideal: 150)

            TableColumn("Title", value: \.title) { item in
                Text(item.title)
                    .fontWeight(item.highSignal ? .semibold : .regular)
                    .help(tooltip(for: item, in: index))
                    .draggable(ItemDragPayload(item))
            }
            .width(min: 200, ideal: 420)

            TableColumn("Kind", value: \.kindLabel) { item in
                Text(item.kindLabel.isEmpty ? "—" : item.kindLabel)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Actor", value: \.actorSortKey) { item in
                Text(item.actorName ?? "—")
                    .foregroundStyle(
                        item.actorName == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Age", value: \.occurredAt) { item in
                HStack(spacing: 4) {
                    Text(PanelFormat.relative(item.occurredAt))
                        .monospacedDigit()
                        .help(PanelFormat.full(item.occurredAt))
                    if item.isSnoozed, let until = item.snoozedUntil {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .help("Snoozed until \(PanelFormat.full(until))")
                            .accessibilityLabel(
                                "Snoozed until \(PanelFormat.full(until))")
                    }
                }
            }
            .width(min: 56, ideal: 76)

            TableColumn("Pin", value: \.pinSortKey) { item in
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.secondary)
                        .help("Pinned — exempt from auto-clear and purge")
                        .accessibilityLabel("Pinned")
                }
            }
            .width(30)
        }
        .contextMenu(forSelectionType: PersistentIdentifier.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            // Double-click, and ⏎ where the table forwards it.
            open(resolve(ids))
        }
        .onKeyPress(phases: .down) { handleKey($0) }
        .overlay { if rows.isEmpty { emptyState } }
        .animation(
            PanelMotion.queue(reduceMotion: reduceMotion), value: rowIDs)
        .popover(
            isPresented: snoozePopoverBinding, attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            SnoozePopover(title: snoozeTargetTitle) { date in
                let targets = resolve(snoozeTargetIDs ?? [])
                snoozeTargetIDs = nil
                snooze(targets, until: date)
            }
        }
        .sheet(item: $topicEditor) { request in
            TopicEditorView(
                request: request,
                members: items.filter { request.memberUIDs.contains($0.uid) },
                existingTopics: allTopics.map {
                    TopicChoice(id: $0.id, name: $0.name)
                },
                existingTerms: allTopics.first { $0.id == request.topicID }?
                    .terms ?? [],
                index: index,
                onClose: { topicEditor = nil })
        }
        .onChange(of: rowIDs) { _, new in
            selection.formIntersection(new)
        }
        .onChange(of: sortOrder) { _, new in persist(sortOrder: new) }
        .onAppear { restoreSortOrder() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some CustomizableToolbarContent {
        ToolbarItem(id: "open", placement: .primaryAction) {
            Button {
                openSelected(andDone: false)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .disabled(selection.isEmpty)
            .help("Open the selected items (⌘O)")
            .accessibilityLabel("Open selected items")
        }
        ToolbarItem(id: "done", placement: .primaryAction) {
            Button {
                doneSelected()
            } label: {
                Label("Done", systemImage: "checkmark.circle")
            }
            .disabled(selection.isEmpty)
            .help("Mark the selected items done (E)")
            .accessibilityLabel("Mark selected items done")
        }
        ToolbarItem(id: "snooze", placement: .primaryAction) {
            Menu {
                ForEach(SnoozePreset.allCases) { preset in
                    Button("\(preset.title) (\(preset.detail))") {
                        snooze(selectedItems, until: preset.date())
                    }
                }
                Divider()
                Button("Pick Date…") { snoozeTargetIDs = selection }
            } label: {
                Label("Snooze", systemImage: "clock.arrow.circlepath")
            }
            .disabled(selection.isEmpty)
            .help("Snooze the selected items (S)")
            .accessibilityLabel("Snooze selected items")
        }
        ToolbarItem(id: "pin", placement: .primaryAction) {
            Button {
                togglePin(selectedItems)
            } label: {
                Label(
                    allSelectedPinned ? "Unpin" : "Pin",
                    systemImage: allSelectedPinned ? "pin.slash" : "pin")
            }
            .disabled(selection.isEmpty)
            .help(
                allSelectedPinned
                    ? "Unpin the selected items (⌘P)"
                    : "Pin the selected items (⌘P)")
            .accessibilityLabel(allSelectedPinned ? "Unpin" : "Pin")
        }
        ToolbarItem(id: "restore", placement: .primaryAction) {
            Button {
                restore(selectedItems)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            .disabled(!canRestore)
            .help("Put the selected archived items back in the queue")
            .accessibilityLabel("Restore selected items")
        }
        ToolbarItem(id: "refresh", placement: .primaryAction) {
            Button {
                refresh()
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing)
            .help("Refresh all sources (⌘R)")
            .accessibilityLabel("Refresh all sources")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            selectionSummary
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if !appState.undoStack.isEmpty {
                Button {
                    appState.undoDone()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Undo last done (⌘Z)")
                .accessibilityLabel("Undo last done")
            }
            HStack(spacing: 4) {
                ForEach(statusSources) { source in
                    SourceStatusDot(
                        display: source, status: appState.statuses[source.id],
                        // A real window renders `.help()` tooltips, so the
                        // in-panel hint bubble isn't needed here — and two
                        // tooltips for one dot would be worse than one.
                        hoveredHint: .constant(nil))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Zero states

    @ViewBuilder private var emptyState: some View {
        if case .all = scope, !isSearching,
            FirstRun.needsFirstSource(kinds: sourceConfigs.map(\.kind))
        {
            WelcomeView()
        } else {
            zeroState
        }
    }

    private var zeroState: some View {
        VStack(spacing: 6) {
            Image(
                systemName: isSearching
                    ? "magnifyingglass" : scope.emptySystemImage)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.headline)
            if let emptyDetail {
                Text(emptyDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if isSearching {
                Button("Clear Search") { searchText = "" }
                    .help("Show every item in this scope")
            }
        }
        .frame(maxWidth: 360)
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private var emptyTitle: String {
        isSearching
            ? "No items match “\(searchText)”" : scope.emptyTitle(in: index)
    }

    private var emptyDetail: String? {
        if isSearching { return "Try a shorter query, or a different scope." }
        if let detail = scope.emptyDetail { return detail }
        guard case .all = scope else { return nil }
        guard let lastRefresh else { return "Waiting for the first sync…" }
        return PanelFormat.refreshed(lastRefresh) + "."
    }

    // MARK: Context menu

    @ViewBuilder private func rowMenu(_ ids: Set<PersistentIdentifier>) -> some View {
        let targets = resolve(ids)
        if targets.isEmpty {
            Button("Refresh All Sources") { refresh() }
        } else {
            let count = targets.count
            let pinned = targets.allSatisfy(\.isPinned)
            Button(title("Open", count)) { open(targets) }
            if targets.contains(where: { !$0.isDone }) {
                Button(title("Open", count, suffix: "and Mark Done")) {
                    open(targets)
                    done(targets)
                }
                Divider()
                Button(title("Mark", count, suffix: "Done")) { done(targets) }
                Menu("Snooze") {
                    ForEach(SnoozePreset.allCases) { preset in
                        Button("\(preset.title) (\(preset.detail))") {
                            snooze(targets, until: preset.date())
                        }
                    }
                    Divider()
                    Button("Pick Date…") { snoozeTargetIDs = ids }
                }
                Button(title(pinned ? "Unpin" : "Pin", count)) {
                    togglePin(targets)
                }
            }
            if targets.contains(where: \.isDone) {
                Divider()
                Button(title("Restore", count, suffix: "to Queue")) {
                    restore(targets)
                }
            }
            Divider()
            Button(title("Copy", count)) { MainWindowPasteboard.copy(targets) }
            if count == 1, let url = targets[0].url {
                Button("Copy Link") {
                    PanelPasteboard.copy(title: targets[0].title, url: url)
                }
            }
        }
    }

    private func title(_ verb: String, _ count: Int, suffix: String = "")
        -> String {
        let tail = suffix.isEmpty ? "" : " \(suffix)"
        return count > 1 ? "\(verb) \(count)\(tail)" : verb + tail
    }

    // MARK: Keyboard

    /// Plain keys only — every ⌘-combination lives in `MainWindowCommands`, so
    /// it stays visible in the menu bar with its shortcut label.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.subtracting(.shift).isEmpty,
            !selection.isEmpty
        else { return .ignored }
        switch press.key.character {
        case KeyEquivalent.return.character:
            openSelected(andDone: false)
            return .handled
        case "e", "E":
            doneSelected()
            return .handled
        case "s", "S":
            snoozeTargetIDs = selection
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: Actions

    private func openSelected(andDone: Bool) {
        let targets = selectedItems
        open(targets)
        if andDone { done(targets) }
    }

    private func doneSelected() { done(selectedItems) }

    private func open(_ targets: [Item]) {
        for item in targets { appState.open(item) }
    }

    /// One action, one undo — a five-row dismissal used to take five ⌘Z.
    private func done(_ targets: [Item]) {
        appState.markDone(targets)
    }

    private func completeSelected() { complete(selectedItems) }

    /// Completing already-done rows is allowed on purpose: dismissing a
    /// reminder leaves the task open in Reminders, so finishing it later from
    /// the archive is exactly the case this has to serve.
    private func complete(_ targets: [Item]) {
        appState.completeTask(targets)
    }

    private func snooze(_ targets: [Item], until date: Date) {
        appState.snooze(targets, until: date)
    }

    /// Mixed selections normalize rather than flip each row: pin everything
    /// unless it is already all pinned, in which case unpin everything. The
    /// rule now lives in `AppState.setPinned`, shared with topics.
    private func togglePin(_ targets: [Item]) {
        guard !targets.isEmpty else { return }
        appState.setPinned(targets, pinned: !targets.allSatisfy(\.isPinned))
    }

    /// ⌘G — group the selection into a topic.
    private func groupSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        topicEditor = .create(targets)
    }

    private func restore(_ targets: [Item]) {
        for item in targets where item.isDone {
            appState.restore(uid: item.uid)
        }
    }

    private func copySelected() { MainWindowPasteboard.copy(selectedItems) }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await appState.engine.refreshNow()
            isRefreshing = false
        }
    }

    private func setScope(_ target: TriageScope) {
        guard target != scope else { return }
        scopeStorage = target.storageValue
        selection = []
    }

    // MARK: Focused value

    private var actions: TriageActions {
        TriageActions(
            scope: scope,
            scopes: scopeShortcuts,
            selection: selection,
            allSelectedPinned: allSelectedPinned,
            canRestore: canRestore,
            canComplete: appState.canCompleteAll(selectedItems),
            canUndoDone: !appState.undoStack.isEmpty,
            isSearchFocused: isSearchFocused,
            revision: appState.queueVersion,
            open: { openSelected(andDone: false) },
            openAndDone: { openSelected(andDone: true) },
            markDone: { doneSelected() },
            completeTask: { completeSelected() },
            snooze: { snooze(selectedItems, until: $0.date()) },
            pickSnoozeDate: { snoozeTargetIDs = selection },
            togglePin: { togglePin(selectedItems) },
            group: { groupSelected() },
            restore: { restore(selectedItems) },
            copy: { copySelected() },
            undoDone: { appState.undoDone() },
            refresh: { refresh() },
            selectScope: { setScope($0) })
    }

    /// ⌘1…⌘4 for the fixed scopes, ⌘5…⌘9 for the first five sources.
    private var scopeShortcuts: [ScopeShortcut] {
        let sources = index
        var result = TriageScope.fixed.enumerated().map { offset, target in
            ScopeShortcut(
                scope: target, title: target.title(in: sources),
                systemImage: target.systemImage(in: sources),
                shortcutNumber: offset + 1)
        }
        for source in sidebarSources {
            let number = result.count + 1
            result.append(
                ScopeShortcut(
                    scope: .source(source.id), title: source.name,
                    systemImage: source.systemImage,
                    shortcutNumber: number <= 9 ? number : nil))
        }
        return result
    }

    // MARK: Derived state

    private var index: SourceIndex {
        SourceIndex(configs: sourceConfigs, items: items)
    }

    private var scope: TriageScope { TriageScope(storageValue: scopeStorage) }

    private var scopeSelection: Binding<TriageScope?> {
        Binding(
            get: { scope },
            set: { newValue in
                guard let newValue else { return }
                setScope(newValue)
            })
    }

    /// Every configured source, plus any source that still has queued items
    /// (a removed-but-not-purged source keeps its row rather than vanishing).
    private var sidebarSources: [SourceDisplay] {
        var ids = Set(sourceConfigs.map(\.id))
        ids.formUnion(items.filter { !$0.isDone }.map(\.sourceID))
        if case .source(let current) = scope { ids.insert(current) }
        return index.ordered(ids: ids)
    }

    private var statusSources: [SourceDisplay] {
        index.ordered(
            ids: Set(sourceConfigs.map(\.id))
                .union(appState.statuses.keys.filter { !$0.isEmpty }))
    }

    /// Sidebar badges, in one pass over the queue.
    private var scopeCounts: [TriageScope: Int] {
        let now = Date.now
        var counts: [TriageScope: Int] = [:]
        for item in items {
            for target in TriageScope.fixed
            where target.contains(item, now: now) {
                counts[target, default: 0] += 1
            }
            if !item.isDone {
                counts[.source(item.sourceID), default: 0] += 1
            }
        }
        return counts
    }

    /// Scope → search → sort. The table displays exactly this order, so
    /// actions run top-to-bottom the way the window reads.
    private var rows: [Item] {
        let now = Date.now
        let current = scope
        var result = items.filter { current.contains($0, now: now) }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            let sources = index
            result = result.filter { item in
                [
                    item.title, item.snippet ?? "", item.actorName ?? "",
                    sources.display(for: item).name,
                ]
                .contains { $0.lowercased().contains(query) }
            }
        }
        return result.sorted(using: sortOrder)
    }

    private var rowIDs: [PersistentIdentifier] { rows.map(\.id) }

    private var selectedItems: [Item] {
        guard !selection.isEmpty else { return [] }
        return rows.filter { selection.contains($0.id) }
    }

    private func resolve(_ ids: Set<PersistentIdentifier>) -> [Item] {
        guard !ids.isEmpty else { return [] }
        return rows.filter { ids.contains($0.id) }
    }

    private var allSelectedPinned: Bool {
        let targets = selectedItems
        return !targets.isEmpty && targets.allSatisfy(\.isPinned)
    }

    private var canRestore: Bool {
        guard case .archive = scope else { return false }
        return !selection.isEmpty
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var subtitle: String {
        let count = rows.count
        let noun = count == 1 ? "item" : "items"
        return isSearching ? "\(count) \(noun) matching" : "\(count) \(noun)"
    }

    private var selectionSummary: Text {
        guard !selection.isEmpty else {
            return rows.isEmpty
                ? Text("No items")
                : Text("^[\(rows.count) item](inflect: true)")
        }
        return Text("\(selection.count) of \(rows.count) selected")
    }

    private var lastRefresh: Date? {
        appState.statuses.values
            .compactMap { status -> Date? in
                if case .ok(let date) = status { return date }
                return nil
            }
            .max()
    }

    private func tooltip(for item: Item, in index: SourceIndex) -> String {
        var lines = [item.title]
        if let snippet = item.snippet, !snippet.isEmpty {
            lines.append(snippet)
        }
        var trailer = index.display(for: item).name
        if let actor = item.actorName, !actor.isEmpty {
            trailer += " · \(actor)"
        }
        trailer += " · \(PanelFormat.full(item.occurredAt))"
        if let until = item.snoozedUntil, item.isSnoozed {
            trailer += " · snoozed until \(PanelFormat.until(until))"
        }
        if let doneAt = item.doneAt {
            trailer += " · done \(PanelFormat.relative(doneAt)) ago"
        }
        lines.append(trailer)
        return lines.joined(separator: "\n")
    }

    private var snoozeTargetTitle: String {
        let targets = resolve(snoozeTargetIDs ?? [])
        guard targets.count != 1 else { return targets[0].title }
        // `SnoozePopover.title` is a plain String (shared with the panel),
        // so the `^[...](inflect: true)` Text markdown isn't available here.
        // count != 1 is guaranteed above, so "items" is always correct.
        return "\(targets.count) items"
    }

    private var snoozePopoverBinding: Binding<Bool> {
        Binding(
            get: { snoozeTargetIDs?.isEmpty == false },
            set: { if !$0 { snoozeTargetIDs = nil } })
    }

    // MARK: Sort persistence (§5.3)

    /// The columns the table can be sorted by, and the persisted string for
    /// each. Adding a column means one new case plus one line in
    /// `comparator(order:)` — `matching(_:)` walks `allCases`, so the reverse
    /// mapping updates itself. This replaces two parallel switches over the
    /// same set of keypaths, which is the shape that silently breaks when
    /// the two get out of step.
    private enum SortKey: String, CaseIterable {
        case age, title, source, kind, actor, pin

        func comparator(order: SortOrder) -> KeyPathComparator<Item> {
            switch self {
            case .age: return KeyPathComparator(\Item.occurredAt, order: order)
            case .title: return KeyPathComparator(\Item.title, order: order)
            case .source: return KeyPathComparator(\Item.sourceKind, order: order)
            case .kind: return KeyPathComparator(\Item.kindLabel, order: order)
            case .actor: return KeyPathComparator(\Item.actorSortKey, order: order)
            case .pin: return KeyPathComparator(\Item.pinSortKey, order: order)
            }
        }

        /// The case whose comparator uses this keypath. Defaults to `.age` for
        /// anything unrecognised, so an old stored value or a future column
        /// with no case yet degrades to the same fallback the table opens on.
        static func matching(_ keyPath: PartialKeyPath<Item>) -> SortKey {
            Self.allCases.first { $0.comparator(order: .forward).keyPath == keyPath } ?? .age
        }
    }

    private func persist(sortOrder: [KeyPathComparator<Item>]) {
        guard let first = sortOrder.first else { return }
        sortAscending = first.order == .forward
        sortKeyStorage = SortKey.matching(first.keyPath).rawValue
    }

    private func restoreSortOrder() {
        let order: SortOrder = sortAscending ? .forward : .reverse
        let key = SortKey(rawValue: sortKeyStorage) ?? .age
        sortOrder = [key.comparator(order: order)]
    }
}
