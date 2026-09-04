import SwiftData
import SwiftUI

/// Sources tab: configured connectors with quick toggles, plus add/edit/
/// delete flows backed by SwiftData + Keychain.
struct SourcesPane: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \SourceConfig.sortOrder) private var sources: [SourceConfig]

    @State private var isAdding = false
    /// The kind the add sheet opens on when the welcome asked for one.
    @State private var addingKind: String?
    @State private var editingSource: SourceConfig?
    @State private var pendingDelete: SourceConfig?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(sources) { source in
                    SourceRow(
                        source: source,
                        onEdit: { editingSource = source },
                        onDelete: { pendingDelete = source })
                }
                .onMove(perform: move)
            }
            BannerPermissionNotice()
                .padding(.horizontal, 10)
                .padding(.top, 8)
            MailPermissionNotice()
            RemindersPermissionNotice()
                .padding(.horizontal, 10)
                .padding(.top, 8)
            AgentHooksNotice()
                .padding(.horizontal, 10)
                .padding(.top, 8)
            HStack {
                Button { isAdding = true } label: {
                    Label("Add Source", systemImage: "plus")
                        .padding(.horizontal, 2)
                }
                .controlSize(.large)
                .help("Add a source")
                Spacer()
            }
            .padding(10)
        }
        .sheet(isPresented: $isAdding, onDismiss: { addingKind = nil }) {
            SourceEditorSheet(initialKind: addingKind)
        }
        .onAppear { consumeAddRequest() }
        .onChange(of: appState.pendingAddSource) { consumeAddRequest() }
        .sheet(item: $editingSource) { source in
            SourceEditorSheet(existing: source)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayName ?? "")”?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let source = pendingDelete { delete(source) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the source and its saved credentials. This cannot be undone.")
        }
    }

    /// Persists the new drag order into `sortOrder` on every affected row —
    /// `sources` is already sorted by that key, so we just renumber it.
    private func move(from offsets: IndexSet, to destination: Int) {
        var reordered = sources
        reordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, source) in reordered.enumerated() {
            source.sortOrder = index
        }
        try? modelContext.save()
    }

    /// The welcome's "Add Apple Mail" lands here: open the add sheet on
    /// that kind, and clear the request so it fires once.
    private func consumeAddRequest() {
        guard let request = appState.pendingAddSource else { return }
        appState.pendingAddSource = nil
        addingKind = request.kind
        isAdding = true
    }

    private func delete(_ source: SourceConfig) {
        let sourceID = source.id
        // The local source is built-in and recreated by bootstrapConnectors()
        // whenever none exists — record that this deletion was deliberate so
        // it doesn't come straight back.
        if source.kind == "local" {
            AppState.localSourceUserRemoved = true
        }
        // Prefix-wipe rather than per-descriptor-field: catches credentials
        // the descriptor no longer lists (e.g. Linear OAuth tokens).
        Keychain.deleteAll(prefix: "\(sourceID).")
        modelContext.delete(source)
        try? modelContext.save()
        Task {
            await appState.engine.unregister(sourceID: sourceID)
            await appState.bootstrapConnectors()
        }
    }
}

private struct SourceRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var source: SourceConfig
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var descriptor: ConnectorKindDescriptor? {
        ConnectorCatalog.descriptor(for: source.kind)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: descriptor?.systemImage ?? "questionmark.circle")
                .font(.system(size: 15))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                Text(descriptor?.displayName ?? source.kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("On", isOn: $source.isEnabled)
                .toggleStyle(.checkbox)
                .help("Enable or disable this source")
                .onChange(of: source.isEnabled) {
                    let sourceID = source.id
                    Task {
                        await appState.engine.unregister(sourceID: sourceID)
                        await appState.bootstrapConnectors()
                    }
                }
            Toggle("Badge", isOn: $source.countsTowardBadge)
                .toggleStyle(.checkbox)
                .help(
                    "Count this source's items toward the menu bar badge. Turn it off to keep the source in the queue but out of the count.")
                .onChange(of: source.countsTowardBadge) {
                    Task { await appState.refreshBadge() }
                }
            Toggle("Banners", isOn: $source.bannersEnabled)
                .toggleStyle(.checkbox)
                .help("Show a notification banner for new items from this source")
                .onChange(of: source.bannersEnabled) {
                    let wantsBanners = source.bannersEnabled
                    Task {
                        // Ask here, not at the first arrival: macOS spends the
                        // permission prompt once, and this is the moment the
                        // user can connect it (or its refusal) to what they
                        // just did.
                        if wantsBanners {
                            await appState.resolveBannerAuthorization(
                                prompting: true)
                        }
                        await appState.refreshBadge()
                    }
                }
            // Only for kinds with something to fold by — a checkbox that
            // does nothing is worse than none.
            if let grouping = descriptor?.grouping {
                Toggle("Group", isOn: groupBinding(default: grouping.defaultOn))
                    .toggleStyle(.checkbox)
                    .help(
                        "Fold this source's rows by \(grouping.noun) in the queue. Turn it off to see every row on its own."
                    )
            }
            Button("Edit", action: onEdit)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Delete this source")
        }
        .padding(.vertical, 6)
    }

    /// nil in the store means "the kind's default", so the checkbox shows
    /// the default until the user takes a position.
    private func groupBinding(default defaultOn: Bool) -> Binding<Bool> {
        Binding(
            get: { source.autoGroups ?? defaultOn },
            set: { on in
                source.autoGroups = on
                // A fold counts as one, so the badge changes with the fold.
                Task { await appState.refreshBadge() }
            })
    }
}
