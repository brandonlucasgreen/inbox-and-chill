import SwiftUI

/// The Reminders source's permission flow, in the two places it belongs:
/// `RemindersAccessSection` in the editor where the source is being set up,
/// and `RemindersPermissionNotice` in the Sources list for every day after.
///
/// Same shape as `MailAccessView`, and the same reason for it: macOS shows its
/// consent dialog once per app, in Apple's words, with no second chance — so
/// the user reads what it is for *first*, and the dialog appears only because
/// they pressed a button with that explanation on screen. Nothing else in the
/// app passes `prompting: true` for Reminders.

/// Read this before macOS asks.
struct RemindersAccessSection: View {
    private var preflight: RemindersAuthorization.Preflight {
        RemindersAuthorization.preflight
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(preflight.title)
                    .font(.callout.weight(.semibold))

                Text(preflight.lead)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(preflight.bullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(bullet)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text(preflight.promptNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                RemindersAccessControl()
            }
            .font(.callout)
            .padding(.vertical, 2)
        }
    }
}

/// The state line plus whatever action that state affords. Shared by the
/// editor section and the Sources-list notice so the two can never disagree
/// about what macOS just said.
struct RemindersAccessControl: View {
    @Environment(AppState.self) private var appState
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch appState.remindersAccess {
            case .granted:
                Label("Reminders access is allowed.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)

            case .notRequested, nil:
                Text(RemindersAuthorization.notRequestedMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    ask()
                } label: {
                    if isAsking {
                        Label("Waiting for macOS…", systemImage: "hourglass")
                    } else {
                        Text("Allow Reminders Access…")
                    }
                }
                .disabled(isAsking)

            case .blocked(let message), .insufficient(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(
                            RemindersAuthorization.systemSettingsURL)
                    }
                    // Granting in System Settings does not notify the app, so
                    // without this the only way back to a working source is to
                    // quit and relaunch.
                    Button("Check Again") { recheck() }
                }
            }
        }
        .task {
            // Never prompting: this runs on appear, and a dialog nobody asked
            // for is the thing being prevented.
            await appState.resolveRemindersAccess(prompting: false)
        }
    }

    private func ask() {
        isAsking = true
        Task {
            await appState.resolveRemindersAccess(prompting: true)
            isAsking = false
        }
    }

    private func recheck() {
        Task { await appState.resolveRemindersAccess(prompting: false) }
    }
}

/// Which reminder lists to pull in, as checkboxes over the real list names.
///
/// A text field would have been less code, and wrong: the names have to match
/// what Reminders calls them, and a typo produces an empty source with nothing
/// to say about why. Names rather than identifiers are still what gets stored
/// — readable in a bug report, and a renamed list is something the connector
/// can *report* instead of quietly matching nothing.
struct RemindersListPicker: View {
    @Environment(AppState.self) private var appState
    /// The comma-separated `lists` setting, edited in place.
    @Binding var value: String

    @State private var available: [String] = []

    private var selected: [String] { TodoScope.parseListNames(value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.remindersAccess?.allowsFetch != true {
                Text("Allow access above to choose lists.")
                    .foregroundStyle(.secondary)
            } else if available.isEmpty {
                Text("Reminders has no lists on this Mac.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(available, id: \.self) { name in
                    Toggle(
                        name,
                        isOn: Binding(
                            get: { selected.contains(name) },
                            set: { toggle(name, on: $0) })
                    )
                    .toggleStyle(.checkbox)
                }
            }

            // A list that was picked and has since been renamed or deleted.
            // Kept visible rather than silently dropped, so the source's
            // emptiness has a cause the user can see (rule 5).
            let orphaned = selected.filter { name in
                !available.contains {
                    $0.caseInsensitiveCompare(name) == .orderedSame
                }
            }
            if !orphaned.isEmpty, appState.remindersAccess?.allowsFetch == true {
                ForEach(orphaned, id: \.self) { name in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(
                            "“\(name)” isn't a list in Reminders any more. Untick it, or rename the list back."
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
        .task(id: appState.remindersAccess) { available = appState.remindersListNames() }
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

/// Reminders permission trouble, said out loud in the Sources list.
///
/// The counterpart to `MailPermissionNotice`, and the same failure class: a
/// refusal leaves a source that looks like an empty to-do list. Silent for the
/// states with nothing to report, and silent entirely when no enabled source
/// needs Reminders.
struct RemindersPermissionNotice: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.hasEnabledRemindersSource {
                switch appState.remindersAccess {
                case .granted, nil:
                    EmptyView()
                default:
                    RemindersAccessControl()
                        .font(.caption)
                }
            }
        }
        // The resolve lives out here, not on the control inside: the outcome
        // starts `nil`, `nil` renders nothing, and a `.task` on the thing that
        // isn't drawn never runs — which reads exactly like permission being
        // fine. Same trap as `MailPermissionNotice`.
        .task {
            guard appState.hasEnabledRemindersSource else { return }
            await appState.resolveRemindersAccess(prompting: false)
        }
    }
}
