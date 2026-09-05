import SwiftData
import SwiftUI

/// Add/edit sheet for a `SourceConfig`. In add mode the user first picks a
/// connector kind (`ConnectorCatalog.all`); in edit mode the kind is fixed
/// and secret fields render blank — leaving one blank keeps its existing
/// Keychain value, typing replaces it.
///
/// Layout note: the fields live in a grouped, scrolling Form inside a fixed
/// frame — content can never clip, it scrolls. Every source is now
/// paste-a-token, and each one's `authNote` explains why that is the only
/// path it has (PLAN §6.9).
struct SourceEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Query private var allSources: [SourceConfig]

    /// nil = adding a new source; non-nil = editing this one in place.
    var existing: SourceConfig?

    @State private var selectedKindID: String
    @State private var name: String
    /// Keyed by field.key. For edit mode, seeded from `existing.settings`
    /// (non-secrets only — secrets are never read back from Keychain).
    @State private var fieldValues: [String: String]

    /// Latches once the setup payload has been copied, so the button can
    /// say so — copying a manifest gives no other feedback that it worked.
    @State private var copiedPayload = false
    /// Why the last Save didn't go through. Non-nil keeps the sheet open.
    @State private var saveErrorText: String?

    /// `initialKind` preselects a kind in add mode — the welcome's buttons
    /// pass one; the Sources pane's own Add button passes nil.
    init(existing: SourceConfig? = nil, initialKind: String? = nil) {
        self.existing = existing
        let initialKind =
            existing?.kind
            ?? initialKind.flatMap { ConnectorCatalog.descriptor(for: $0)?.id }
            ?? ConnectorCatalog.all.first!.id
        _selectedKindID = State(initialValue: initialKind)
        _name = State(
            initialValue: existing?.displayName
                ?? ConnectorCatalog.descriptor(for: initialKind)?.displayName ?? "")
        let settings = existing?.settings ?? [:]
        _fieldValues = State(initialValue: settings)
    }

    private var descriptor: ConnectorKindDescriptor {
        ConnectorCatalog.descriptor(for: selectedKindID) ?? ConnectorCatalog.all[0]
    }

    /// Kinds already configured — only matters for `!allowsMultiple` kinds
    /// (Apple Mail: one Mac has one Mail.app database, so a second source
    /// would just watch the same account twice).
    private var existingKinds: Set<String> {
        Set(allSources.map(\.kind))
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
                                    .disabled(
                                        !kind.allowsMultiple
                                            && existingKinds.contains(kind.id))
                            }
                        }
                        .onChange(of: selectedKindID) { _, newValue in
                            name = ConnectorCatalog.descriptor(for: newValue)?
                                .displayName ?? ""
                            fieldValues = [:]
                            copiedPayload = false
                        }
                        // What this kind will ask of you, before any field
                        // asks it — so Slack's five steps are a choice made
                        // knowingly rather than discovered halfway down.
                        Text(descriptor.setupCostLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        LabeledContent("Kind") {
                            Label(descriptor.displayName, systemImage: descriptor.systemImage)
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextField("Name", text: $name)
                }

                if !descriptor.setupSteps.isEmpty {
                    Section("How to get set up") { setupSteps }
                }

                // Above the toggles for the same reason the setup steps
                // are: this is what you need before deciding anything. It is
                // also the only place in the app that can raise macOS's
                // Automation dialog, and it does so from a button.
                if descriptor.id == "appleMail" {
                    MailAccessSection()
                }

                // Same placement argument as Mail's: the local source can
                // receive nothing until each coding agent is told where to
                // post, so the setup belongs with the source rather than in
                // General, where it used to sit.
                if descriptor.id == "local" {
                    AgentHooksSection()
                }

                // Same argument again, and one addition: the list picker below
                // can only show real list names once access exists, so the
                // permission control has to come first on the page rather than
                // beside the fields.
                if descriptor.id == "reminders" {
                    RemindersAccessSection()
                }

                if !descriptor.fields.isEmpty {
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

    // MARK: Setup steps

    /// Numbered instructions, the provider's page, and anything its console
    /// asks you to paste.
    ///
    /// Above the fields on purpose: you read these *before* you have a token
    /// to paste, and the reasoning (`authNote`) stays underneath for anyone
    /// who wants it.
    @ViewBuilder private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(descriptor.setupSteps.enumerated()), id: \.offset) {
                index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(Self.formatted(step))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if !descriptor.setupURL.isEmpty || descriptor.setupPayload != nil {
                HStack(spacing: 8) {
                    if let url = URL(string: descriptor.setupURL) {
                        Link(destination: url) {
                            Label(
                                Self.hostLabel(descriptor.setupURL),
                                systemImage: "arrow.up.forward.square")
                        }
                    }
                    if let payload = descriptor.setupPayload {
                        Button {
                            PanelPasteboard.copy(
                                title: payload.text, url: nil)
                            copiedPayload = true
                        } label: {
                            Label(
                                copiedPayload
                                    ? "Copied" : "Copy \(payload.label)",
                                systemImage: copiedPayload
                                    ? "checkmark" : "doc.on.doc")
                        }
                        .disabled(copiedPayload)
                    }
                }
                .font(.callout)
                .padding(.top, 2)
            }
        }
        .font(.callout)
        .padding(.vertical, 2)
    }

    /// Inline markdown — bold for the things to click, code for the things
    /// to type. Falls back to the raw text rather than dropping a step.
    private static func formatted(_ step: String) -> AttributedString {
        (try? AttributedString(
            markdown: step,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(step)
    }

    /// "api.slack.com" rather than the whole URL: the button is already the
    /// link, and the host is the part that says where you're going.
    private static func hostLabel(_ urlString: String) -> String {
        URL(string: urlString)?.host() ?? urlString
    }

    /// The network to-do sources whose `projects` field is a picker rather
    /// than a text field, with the call that fills it. Adding a provider here
    /// is the whole UI change it needs.
    private static func projectPicker(
        for kind: String
    ) -> (name: String, load: @Sendable (String) async throws -> [String])? {
        switch kind {
        case "todoist":
            return ("Todoist", { try await TodoistConnector.projects(token: $0).map(\.name) })
        case "asana":
            return ("Asana", { try await AsanaConnector.projectNames(token: $0) })
        default:
            return nil
        }
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
        } else if let picker = Self.projectPicker(for: descriptor.id), field.key == "projects" {
            // Checkboxes over the account's real project names, for the same
            // reason Reminders gets them — and here the picker is also what
            // proves the token works, so it replaces a separate connection
            // test rather than sitting beside one.
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                TodoProjectPicker(
                    value: binding,
                    typedToken: fieldValues["token"] ?? "",
                    sourceID: existing?.id,
                    providerName: picker.name,
                    loadProjects: picker.load)
                if !field.help.isEmpty {
                    Text(field.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if descriptor.id == "reminders", field.key == "lists" {
            // Checkboxes over the real list names instead of a text field: the
            // names have to match what Reminders calls them, and a typo would
            // produce an empty source with nothing to say about why.
            VStack(alignment: .leading, spacing: 4) {
                Text(field.label)
                RemindersListPicker(value: binding)
                if !field.help.isEmpty {
                    Text(field.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
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
        let opensQueue = FirstRun.shouldOpenQueueAfterSave(
            wasAdding: existing == nil, sourcesBefore: allSources.count)
        if existing == nil { modelContext.insert(target) }
        do {
            try modelContext.save()
        } catch {
            saveErrorText =
                "Couldn't save this source — \(error.localizedDescription)"
            return
        }
        Task {
            await appState.bootstrapConnectors()
            // The very first source: finish the story the welcome started
            // by showing where the queue lives, rather than leaving the
            // user in Settings looking at a list of one.
            if opensQueue {
                try? await Task.sleep(for: .milliseconds(600))
                PanelToggler.toggle()
            }
        }
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
        if descriptor.id == "linear" { clearLinearOAuthLeftovers(from: config) }
        return nil
    }

    /// Clears credentials left by the "Sign in with Linear" flow, removed
    /// 2026-08-19.
    ///
    /// Saving a Linear source is the one moment the app can reach them: the
    /// UI that wrote them is gone, and access tokens nobody can use are
    /// still secrets sitting in the Keychain. Deleting the settings keys too
    /// keeps a stale `authMethod` from meaning anything to a later build.
    private func clearLinearOAuthLeftovers(from config: SourceConfig) {
        for key in ["oauthAccessToken", "oauthRefreshToken", "oauthExpiresAt"] {
            Keychain.delete("\(config.id).\(key)")
        }
        config.settings["authMethod"] = nil
        config.settings["oauthClientID"] = nil
    }

}
