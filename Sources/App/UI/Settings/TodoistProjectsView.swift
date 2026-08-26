import SwiftUI

/// Which Todoist projects to pull in, as checkboxes over the account's real
/// project names — the network counterpart of `RemindersListPicker`.
///
/// **It is also the only place a Todoist token gets checked before it is
/// used.** That is deliberate, and it is the rule-5 half of this source: a
/// wrong or expired token produces a source that returns nothing, which for a
/// to-do list is indistinguishable from having nothing due. Loading the
/// projects is the cheapest possible call that proves the token works, so the
/// picker doubles as the connection test and there is no second "Check
/// Connection" control saying the same thing twice (the 2026-08-26 copy note).
///
/// The token is read from what the user has just typed, falling back to the
/// Keychain — in edit mode the secret field renders blank on purpose, so
/// "blank" means "keep the saved one" here exactly as it does on save.
struct TodoistProjectPicker: View {
    /// The comma-separated `projects` setting, edited in place.
    @Binding var value: String
    /// What is currently typed into the token field, which may be nothing.
    var typedToken: String
    /// nil while adding a source that has never been saved.
    var sourceID: String?

    @State private var state: LoadState = .idle

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([String])
        case failed(String)
    }

    private var selected: [String] { TodoScope.parseListNames(value) }

    private var token: String {
        let typed = typedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        guard let sourceID, !sourceID.isEmpty else { return "" }
        return Keychain.get("\(sourceID).token") ?? ""
    }

    private var available: [String] {
        if case .loaded(let names) = state { return names }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .idle:
                if token.isEmpty {
                    Text("Paste your API token above to choose projects.")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Load Projects") { loadNow() }
                }

            case .loading:
                // A static glyph, not a ProgressView: the offscreen renderer
                // this project uses for visual checks draws ProgressView as a
                // prohibition sign, and "loading" reading as "forbidden" is a
                // bad half-second.
                Label("Asking Todoist…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)

            case .loaded(let names):
                if names.isEmpty {
                    Text("That account has no projects.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(names, id: \.self) { name in
                        Toggle(
                            name,
                            isOn: Binding(
                                get: { isSelected(name) },
                                set: { toggle(name, on: $0) })
                        )
                        .toggleStyle(.checkbox)
                    }
                }

            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { loadNow() }
            }

            orphanedNotice
        }
        // Keyed on the token so pasting a new one re-checks it against the
        // right account, rather than leaving the previous one's projects on
        // screen. The work happens *inside* the task rather than in a detached
        // one so SwiftUI's own cancellation debounces it: a token arrives one
        // character at a time when typed, and a request per keystroke is a
        // good way to meet Todoist's rate limiter on your first try.
        .task(id: token) { await reload() }
    }

    /// A project that was ticked and has since been renamed or deleted.
    ///
    /// Kept on screen rather than silently dropped, so the source's emptiness
    /// has a cause the user can see — the same argument as the Reminders
    /// picker, and the connector says the same thing from its side.
    @ViewBuilder private var orphanedNotice: some View {
        if case .loaded = state {
            let orphaned = selected.filter { name in
                !available.contains {
                    $0.caseInsensitiveCompare(name) == .orderedSame
                }
            }
            ForEach(orphaned, id: \.self) { name in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(
                        "“\(name)” isn't a project in Todoist any more. Untick it, or rename the project back."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Remove") { toggle(name, on: false) }
                        .buttonStyle(.link)
                }
                .foregroundStyle(.orange)
                .font(.caption)
            }
        }
    }

    private func isSelected(_ name: String) -> Bool {
        selected.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Debounced by cancellation: `.task(id:)` restarts this whenever the
    /// token changes, and the sleep is the window in which that costs nothing.
    private func reload() async {
        let token = token
        guard !token.isEmpty else {
            state = .idle
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        await load(token: token)
    }

    /// The button's path, which skips the debounce — the user has already
    /// waited, and pressing Try Again should visibly do something.
    private func loadNow() {
        let token = token
        guard !token.isEmpty else { return }
        Task { await load(token: token) }
    }

    private func load(token: String) async {
        state = .loading
        do {
            let projects = try await TodoistConnector.projects(token: token)
            guard !Task.isCancelled else { return }
            state = .loaded(projects.map(\.name))
        } catch {
            guard !Task.isCancelled else { return }
            // `TodoistError` already says what to do about each status — 401
            // names where to re-copy the token — so this passes the connector's
            // own wording through rather than inventing a second, vaguer one.
            state = .failed(String(describing: error))
        }
    }

    private func toggle(_ name: String, on: Bool) {
        var names = selected.filter {
            $0.caseInsensitiveCompare(name) != .orderedSame
        }
        if on { names.append(name) }
        // Keep the picker's own order rather than click order, so the stored
        // string doesn't shuffle every time a box is ticked.
        let order = available
        names.sort { a, b in
            (order.firstIndex(of: a) ?? .max) < (order.firstIndex(of: b) ?? .max)
        }
        value = TodoScope.joinListNames(names)
    }
}
