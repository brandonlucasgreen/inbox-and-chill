import SwiftData
import SwiftUI

/// Add/edit sheet for a `SourceConfig`. In add mode the user first picks a
/// connector kind (`ConnectorCatalog.all`); in edit mode the kind is fixed
/// and secret fields render blank — leaving one blank keeps its existing
/// Keychain value, typing replaces it.
struct SourceEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// nil = adding a new source; non-nil = editing this one in place.
    var existing: SourceConfig?

    @State private var selectedKindID: String
    @State private var name: String
    /// Keyed by field.key. For edit mode, seeded from `existing.settings`
    /// (non-secrets only — secrets are never read back from Keychain).
    @State private var fieldValues: [String: String]

    init(existing: SourceConfig? = nil) {
        self.existing = existing
        let initialKind = existing?.kind ?? ConnectorCatalog.all.first!.id
        _selectedKindID = State(initialValue: initialKind)
        _name = State(
            initialValue: existing?.displayName
                ?? ConnectorCatalog.descriptor(for: initialKind)?.displayName ?? "")
        _fieldValues = State(initialValue: existing?.settings ?? [:])
    }

    private var descriptor: ConnectorKindDescriptor {
        ConnectorCatalog.descriptor(for: selectedKindID) ?? ConnectorCatalog.all[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Add Source" : "Edit Source")
                .font(.headline)

            Form {
                if existing == nil {
                    Picker("Kind", selection: $selectedKindID) {
                        ForEach(ConnectorCatalog.all) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage)
                                .tag(kind.id)
                        }
                    }
                    .onChange(of: selectedKindID) { _, newValue in
                        name = ConnectorCatalog.descriptor(for: newValue)?.displayName ?? ""
                        fieldValues = [:]
                    }
                } else {
                    Label(descriptor.displayName, systemImage: descriptor.systemImage)
                        .foregroundStyle(.secondary)
                }

                TextField("Name", text: $name)

                ForEach(descriptor.fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        fieldEditor(for: field)
                            .help(field.help)
                        if !field.help.isEmpty {
                            Text(field.help)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    @ViewBuilder
    private func fieldEditor(for field: ConnectorKindDescriptor.Field) -> some View {
        let binding = Binding<String>(
            get: { fieldValues[field.key] ?? "" },
            set: { fieldValues[field.key] = $0 })
        if field.isSecret {
            SecureField(
                field.label, text: binding,
                prompt: Text(
                    existing != nil ? "•••• saved — enter to replace" : field.placeholder))
        } else {
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
        }
    }

    private func save() {
        if let existing {
            existing.displayName = name
            applyFields(to: existing, descriptor: descriptor)
        } else {
            let config = SourceConfig(
                kind: descriptor.id, displayName: name,
                bannersEnabled: descriptor.bannersDefaultOn)
            modelContext.insert(config)
            applyFields(to: config, descriptor: descriptor)
        }
        try? modelContext.save()
        Task { await appState.bootstrapConnectors() }
        dismiss()
    }

    private func applyFields(to config: SourceConfig, descriptor: ConnectorKindDescriptor) {
        for field in descriptor.fields {
            let value = fieldValues[field.key] ?? ""
            if field.isSecret {
                guard !value.isEmpty else { continue }
                Keychain.set(value, for: "\(config.id).\(field.key)")
            } else {
                config.settings[field.key] = value
            }
        }
    }
}
