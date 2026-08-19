import SwiftData
import SwiftUI

/// Add/edit sheet for a `SourceConfig`. In add mode the user first picks a
/// connector kind (`ConnectorCatalog.all`); in edit mode the kind is fixed
/// and secret fields render blank — leaving one blank keeps its existing
/// Keychain value, typing replaces it.
///
/// Layout note: the fields live in a grouped, scrolling Form inside a fixed
/// frame — content can never clip, it scrolls. Linear gets a custom
/// authentication section (API key or OAuth sign-in, PLAN §6.9); GitHub and
/// Slack render an explanation of why paste-a-token is their only path.
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

    // Linear authentication state.
    private enum LinearAuthMethod: String {
        case apiKey, oauth
    }
    @State private var linearAuthMethod: LinearAuthMethod
    /// Tokens from a completed sign-in, held here until Save writes them to
    /// the Keychain under the (possibly not-yet-created) source's id.
    @State private var pendingOAuthTokens: LinearOAuth.Tokens?
    @State private var isSigningIn = false
    @State private var oauthErrorText: String?
    /// Why the last Save didn't go through. Non-nil keeps the sheet open.
    @State private var saveErrorText: String?

    init(existing: SourceConfig? = nil) {
        self.existing = existing
        let initialKind = existing?.kind ?? ConnectorCatalog.all.first!.id
        _selectedKindID = State(initialValue: initialKind)
        _name = State(
            initialValue: existing?.displayName
                ?? ConnectorCatalog.descriptor(for: initialKind)?.displayName ?? "")
        let settings = existing?.settings ?? [:]
        _fieldValues = State(initialValue: settings)
        _linearAuthMethod = State(
            initialValue: settings["authMethod"] == "oauth" ? .oauth : .apiKey)
    }

    private var descriptor: ConnectorKindDescriptor {
        ConnectorCatalog.descriptor(for: selectedKindID) ?? ConnectorCatalog.all[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(existing == nil ? "Add Source" : "Edit Source")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Form {
                Section {
                    if existing == nil {
                        Picker("Kind", selection: $selectedKindID) {
                            ForEach(ConnectorCatalog.all) { kind in
                                Label(kind.displayName, systemImage: kind.systemImage)
                                    .tag(kind.id)
                            }
                        }
                        .onChange(of: selectedKindID) { _, newValue in
                            name = ConnectorCatalog.descriptor(for: newValue)?
                                .displayName ?? ""
                            fieldValues = [:]
                            pendingOAuthTokens = nil
                            oauthErrorText = nil
                        }
                    } else {
                        LabeledContent("Kind") {
                            Label(descriptor.displayName, systemImage: descriptor.systemImage)
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextField("Name", text: $name)
                }

                if descriptor.id == "linear" {
                    linearAuthSection
                } else if !descriptor.fields.isEmpty {
                    Section {
                        ForEach(descriptor.fields) { field in
                            fieldRow(for: field)
                        }
                    }
                }

                if !descriptor.authNote.isEmpty {
                    Section {
                        Text(descriptor.authNote)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let saveErrorText {
                    Label(saveErrorText, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }

    // MARK: Generic fields

    @ViewBuilder
    private func fieldRow(for field: ConnectorKindDescriptor.Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldEditor(for: field)
                .help(field.help)
            if !field.help.isEmpty {
                Text(field.help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fieldEditor(for field: ConnectorKindDescriptor.Field) -> some View {
        let binding = Binding<String>(
            get: { fieldValues[field.key] ?? "" },
            set: { fieldValues[field.key] = $0 })
        if field.isToggle {
            Toggle(
                field.label,
                isOn: Binding(
                    get: { (fieldValues[field.key] ?? "").isEmpty
                        ? field.defaultOn : fieldValues[field.key] == "true" },
                    set: { fieldValues[field.key] = $0 ? "true" : "false" }))
                .toggleStyle(.checkbox)
        } else if field.isSecret {
            SecureField(
                field.label, text: binding,
                prompt: Text(
                    existing != nil ? "•••• saved — enter to replace" : field.placeholder))
        } else {
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
        }
    }

    // MARK: Linear authentication

    private var linearAPIKeyField: ConnectorKindDescriptor.Field? {
        descriptor.fields.first { $0.key == "apiKey" }
    }

    @ViewBuilder private var linearAuthSection: some View {
        Section("Authentication") {
            Picker("Method", selection: $linearAuthMethod) {
                Text("Personal API Key").tag(LinearAuthMethod.apiKey)
                Text("Sign in with Linear").tag(LinearAuthMethod.oauth)
            }
            .pickerStyle(.segmented)

            if linearAuthMethod == .apiKey {
                if let field = linearAPIKeyField {
                    fieldRow(for: field)
                }
            } else {
                TextField(
                    "OAuth Client ID",
                    text: Binding(
                        get: { fieldValues["oauthClientID"] ?? "" },
                        set: { fieldValues["oauthClientID"] = $0 }),
                    prompt: Text("From your Linear OAuth application"))

                LabeledContent("Callback URL") {
                    Text(LinearOAuth.redirectURI)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                .help("Register this exact URL on your Linear OAuth application")

                HStack(spacing: 10) {
                    Button {
                        signInWithLinear()
                    } label: {
                        if isSigningIn {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(oauthConnected ? "Re-connect…" : "Sign in with Linear…")
                        }
                    }
                    .disabled(isSigningIn || trimmedClientID.isEmpty)

                    if oauthConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }

                if let oauthErrorText {
                    Text(oauthErrorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(
                    "Create an OAuth application in Linear (Settings → API → OAuth applications), add the callback URL above, and paste its client ID — no client secret needed. Tokens are stored in your Keychain and refreshed automatically."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trimmedClientID: String {
        (fieldValues["oauthClientID"] ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Connected = tokens from this sheet session, or (edit mode) tokens
    /// already in the Keychain for this source.
    private var oauthConnected: Bool {
        if pendingOAuthTokens != nil { return true }
        guard let existing else { return false }
        return LinearOAuth.isConnected(sourceID: existing.id)
    }

    private func signInWithLinear() {
        let clientID = trimmedClientID
        isSigningIn = true
        oauthErrorText = nil
        Task {
            do {
                pendingOAuthTokens = try await LinearOAuth.signIn(clientID: clientID)
            } catch {
                oauthErrorText = String(describing: error)
            }
            isSigningIn = false
        }
    }

    // MARK: Save

    /// Saving is allowed to fail, and when it does the sheet stays open.
    ///
    /// A secret that didn't reach the Keychain leaves a source that looks
    /// configured and can't authenticate — the failure the app exists to
    /// stop. Dismissing on a failed write would hide the one moment the
    /// user could still fix it.
    private func save() {
        let target: SourceConfig
        if let existing {
            existing.displayName = name
            target = existing
        } else {
            target = SourceConfig(
                kind: descriptor.id, displayName: name,
                bannersEnabled: descriptor.bannersDefaultOn)
        }
        if let problem = applyFields(to: target, descriptor: descriptor) {
            saveErrorText = problem
            return
        }
        saveErrorText = nil
        if existing == nil { modelContext.insert(target) }
        do {
            try modelContext.save()
        } catch {
            saveErrorText =
                "Couldn't save this source — \(error.localizedDescription)"
            return
        }
        Task { await appState.bootstrapConnectors() }
        dismiss()
    }

    /// Returns `nil` when every field landed, or the first problem.
    ///
    /// Secrets are written before the config is inserted, so a Keychain
    /// failure can't leave a half-configured source behind in SwiftData.
    private func applyFields(
        to config: SourceConfig, descriptor: ConnectorKindDescriptor
    ) -> String? {
        for field in descriptor.fields {
            let value = fieldValues[field.key] ?? ""
            if field.isSecret {
                guard !value.isEmpty else { continue }
                if let problem = Keychain.set(
                    value, for: "\(config.id).\(field.key)")
                {
                    return problem
                }
            } else {
                config.settings[field.key] = value
            }
        }
        if descriptor.id == "linear" {
            return applyLinearAuth(to: config)
        }
        return nil
    }

    /// The two Linear auth methods are exclusive: committing to one clears
    /// the other's Keychain material so the connector's "OAuth token present
    /// → use OAuth" check can't pick up stale credentials.
    private func applyLinearAuth(to config: SourceConfig) -> String? {
        config.settings["authMethod"] = linearAuthMethod.rawValue
        config.settings["oauthClientID"] = trimmedClientID
        switch linearAuthMethod {
        case .apiKey:
            LinearOAuth.clear(sourceID: config.id)
        case .oauth:
            if let tokens = pendingOAuthTokens,
                let problem = LinearOAuth.store(tokens, sourceID: config.id)
            {
                // Deliberately before the apiKey delete: leaving the key in
                // place is what keeps the source working when the tokens
                // didn't store.
                return problem
            }
            Keychain.delete("\(config.id).apiKey")
        }
        return nil
    }
}
