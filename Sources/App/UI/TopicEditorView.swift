import SwiftUI

/// What the editor was opened for.
///
/// Carries uids rather than `Item`s: a poll can archive a row while the card
/// is open, and holding the objects would leave the sheet acting on something
/// that has left the queue.
struct TopicEditorRequest: Identifiable, Equatable {
    /// The topic being edited, or nil when making a new one.
    var topicID: String?
    var memberUIDs: [String]

    var id: String { topicID ?? "new:\(memberUIDs.joined(separator: ","))" }
    var isEditing: Bool { topicID != nil }

    static func create(_ items: [Item]) -> TopicEditorRequest {
        TopicEditorRequest(topicID: nil, memberUIDs: items.map(\.uid))
    }

    static func edit(_ topic: TopicGroup) -> TopicEditorRequest {
        TopicEditorRequest(topicID: topic.id, memberUIDs: topic.memberUIDs)
    }
}

/// One existing topic, as the picker needs it.
struct TopicChoice: Identifiable, Hashable {
    var id: String
    var name: String
}

/// Name a topic, choose what it should catch, or file rows into one that
/// already exists.
///
/// Rendered as a card inside the panel rather than as a `.sheet`: the panel
/// is a `MenuBarExtra(.window)`, and a real sheet there fights the same
/// window-key problem `PanelKeyboardFocus` exists to solve. The main window
/// presents the same view in a proper sheet.
struct TopicEditorView: View {
    @Environment(AppState.self) private var appState

    let request: TopicEditorRequest
    /// Members, resolved fresh by the caller so a row archived while this was
    /// open simply isn't there.
    let members: [Item]
    /// Every topic that already exists, for the "file it under" picker.
    let existingTopics: [TopicChoice]
    /// The topic's current catch terms, when editing one.
    let existingTerms: [String]
    let index: SourceIndex
    var onClose: () -> Void

    @State private var name = ""
    @State private var terms: [Term] = []
    @State private var customTerm = ""
    @State private var destination: Destination = .new
    @State private var didPrepare = false
    @FocusState private var nameFocused: Bool

    private struct Term: Identifiable, Equatable {
        var id: String { text }
        var text: String
        var isOn: Bool
    }

    private enum Destination: Hashable {
        case new
        case existing(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if case .existing = destination {} else { nameField }
            if !existingTopics.isEmpty && !request.isEditing { destinationPicker }
            if case .new = destination { termsSection }
            Divider()
            buttons
        }
        .padding(16)
        .frame(width: 356)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1))
        .shadow(radius: 24, y: 8)
        .onAppear(perform: prepare)
        .onExitCommand(perform: onClose)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.isEditing ? "Edit Topic" : "New Topic")
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Name")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("What is this about?", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($nameFocused)
                .onSubmit(commit)
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("File it under")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("File it under", selection: $destination) {
                Text("A new topic").tag(Destination.new)
                ForEach(existingTopics) { topic in
                    Text(topic.name).tag(Destination.existing(topic.id))
                }
            }
            .labelsHidden()
            .font(.system(size: 13))
        }
    }

    private var termsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Catch new items mentioning")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(
                    terms.isEmpty
                        ? "These items share no identifier, so new ones won't join on their own. You can add a term yourself."
                        : "Anything arriving later that mentions a ticked term joins this topic."
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($terms) { $term in
                Toggle(isOn: $term.isOn) {
                    Text(term.text)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                TextField("Add a term…", text: $customTerm)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(addCustomTerm)
                Button("Add", action: addCustomTerm)
                    .font(.system(size: 12))
                    .disabled(
                        customTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if request.isEditing {
                Button("Ungroup", role: .destructive) {
                    if let id = request.topicID { appState.deleteTopic(id: id) }
                    onClose()
                }
                .font(.system(size: 12))
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(primaryTitle, action: commit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
        }
    }

    // MARK: Behaviour

    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        let fields = members.map {
            TopicMatcher.Fields(
                title: $0.title, snippet: $0.snippet, url: $0.urlString)
        }
        if request.isEditing, let existing = existingTopics.first(where: {
            $0.id == request.topicID
        }) {
            name = existing.name
            terms = existingTerms.map { Term(text: $0, isOn: true) }
        } else {
            name = TopicMatcher.suggestedName(for: fields)
            terms = TopicMatcher.suggestedTerms(for: fields).map {
                // Suggested terms arrive ticked. They were measured to be
                // the thing that actually crosses sources, and a topic with
                // no rule quietly stops being true by lunchtime.
                Term(text: $0, isOn: true)
            }
        }
        nameFocused = !request.isEditing
    }

    private func addCustomTerm() {
        let text = customTerm.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
            !terms.contains(where: { $0.text.lowercased() == text.lowercased() })
        else {
            customTerm = ""
            return
        }
        terms.append(Term(text: text, isOn: true))
        customTerm = ""
    }

    private func commit() {
        guard canCommit else { return }
        switch destination {
        case .existing(let id):
            appState.addToTopic(id: id, members: members)
        case .new:
            let chosen = terms.filter(\.isOn).map(\.text)
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if let id = request.topicID {
                appState.renameTopic(id: id, name: trimmed, terms: chosen)
            } else {
                appState.createTopic(
                    name: trimmed, terms: chosen, members: members)
            }
        }
        onClose()
    }

    private var canCommit: Bool {
        switch destination {
        case .existing: return !members.isEmpty
        case .new:
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
                && (request.isEditing || !members.isEmpty)
        }
    }

    private var primaryTitle: String {
        switch destination {
        case .existing: return "Add"
        case .new: return request.isEditing ? "Save" : "Create"
        }
    }

    private var subtitle: String {
        guard !members.isEmpty else {
            return "This topic has nothing in it right now."
        }
        let sources = index.ordered(ids: Set(members.map(\.sourceID)))
            .map(\.name)
            .formatted(.list(type: .and))
        let count = members.count == 1 ? "1 item" : "\(members.count) items"
        return "\(count) · \(sources)"
    }
}
