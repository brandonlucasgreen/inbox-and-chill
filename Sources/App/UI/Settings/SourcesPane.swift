import SwiftData
import SwiftUI

/// Sources tab: configured connectors with quick toggles, plus add/edit/
/// delete flows backed by SwiftData + Keychain.
struct SourcesPane: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \SourceConfig.sortOrder) private var sources: [SourceConfig]

    @State private var isAdding = false
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
            }
            HStack {
                Button { isAdding = true } label: {
                    Image(systemName: "plus")
                }
                .help("Add a source")
                Spacer()
            }
            .padding(8)
        }
        .sheet(isPresented: $isAdding) {
            SourceEditorSheet()
        }
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

    private func delete(_ source: SourceConfig) {
        let sourceID = source.id
        for field in ConnectorCatalog.descriptor(for: source.kind)?.fields ?? []
        where field.isSecret {
            Keychain.delete("\(sourceID).\(field.key)")
        }
        modelContext.delete(source)
        try? modelContext.save()
        Task {
            await appState.engine.unregister(sourceID: sourceID)
            await appState.bootstrapConnectors()
        }
    }
}

private struct SourceRow: View {
    @Bindable var source: SourceConfig
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var descriptor: ConnectorKindDescriptor? {
        ConnectorCatalog.descriptor(for: source.kind)
    }

    var body: some View {
        HStack {
            Image(systemName: descriptor?.systemImage ?? "questionmark.circle")
                .frame(width: 20)
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
            Toggle("Badge", isOn: $source.countsTowardBadge)
                .toggleStyle(.checkbox)
                .help("Count this source's items toward the menu bar badge")
            Toggle("Banners", isOn: $source.bannersEnabled)
                .toggleStyle(.checkbox)
                .help("Show a notification banner for new items from this source")
            Button("Edit", action: onEdit)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete this source")
        }
        .padding(.vertical, 2)
    }
}
