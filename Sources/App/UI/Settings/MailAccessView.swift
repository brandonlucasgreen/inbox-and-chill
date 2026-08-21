import SwiftUI

/// The Apple Mail source's permission flow, in the two places it belongs:
/// `MailAccessSection` in the editor where the source is being set up, and
/// `MailPermissionNotice` in the Sources list for every day after that.
///
/// The order is the whole design. macOS shows its Automation dialog once per
/// app per target, in Apple's words, with no second chance — so the user
/// reads what it is for *first*, and the dialog appears only because they
/// pressed a button with that explanation on screen. Nothing else in the app
/// passes `prompting: true`.

/// Read this before macOS asks. Lives above the toggles in the editor sheet
/// for the same reason the setup steps do: it is what you need before you
/// have decided anything, not after.
struct MailAccessSection: View {
    private var preflight: MailAutomationAuthorization.Preflight {
        MailAutomationAuthorization.preflight
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

                Text(preflight.coldNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                MailAccessControl()
            }
            .font(.callout)
            .padding(.vertical, 2)
        }
    }
}

/// The state line plus whatever action that state affords. Shared by the
/// editor section and the Sources-list notice so the two can never disagree
/// about what macOS just said.
struct MailAccessControl: View {
    @Environment(AppState.self) private var appState
    /// Set while the prompting call is parked waiting for the user to answer
    /// the macOS dialog — it blocks, so the button must not look idle.
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch appState.mailAutomation {
            case .granted:
                Label("Mail access is allowed.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)

            case .notRequested, nil:
                Text(MailAutomationAuthorization.notRequestedMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    ask()
                } label: {
                    if isAsking {
                        // The call parks until the dialog is answered, and a
                        // button that stays clickable through that invites a
                        // second prompt that will never come.
                        Label("Waiting for macOS…", systemImage: "hourglass")
                    } else {
                        Text("Allow Mail Access…")
                    }
                }
                .disabled(isAsking)

            case .blocked(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(
                            MailAutomationAuthorization.systemSettingsURL)
                    }
                    // Granting in System Settings does not notify the app, so
                    // without this the only way back to a working source is
                    // to quit and relaunch.
                    Button("Check Again") { recheck() }
                }

            case .mailNotRunning:
                Text(MailAutomationAuthorization.mailNotRunningMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check Again") { recheck() }
            }
        }
        .task {
            // Never prompting: this runs on appear, and a dialog nobody asked
            // for is the thing being fixed.
            await appState.resolveMailAutomation(prompting: false)
        }
    }

    private func ask() {
        isAsking = true
        Task {
            await appState.resolveMailAutomation(prompting: true)
            isAsking = false
        }
    }

    private func recheck() {
        Task { await appState.resolveMailAutomation(prompting: false) }
    }
}

/// Mail permission trouble, said out loud in the Sources list.
///
/// The counterpart to `BannerPermissionNotice`, and the same failure class:
/// macOS refusing the Apple event leaves a source that looks like an inbox
/// with nothing in it. Silent for the states with nothing to report — and
/// silent entirely when no enabled source needs Mail.
struct MailPermissionNotice: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.hasEnabledMailSource {
                switch appState.mailAutomation {
                case .granted, nil:
                    EmptyView()
                default:
                    MailAccessControl()
                        .font(.caption)
                }
            }
        }
        // The resolve has to live out here, not on the control inside: the
        // outcome starts `nil`, `nil` renders nothing, and a `.task` on the
        // thing that isn't drawn yet never runs. That read the same as
        // permission being fine.
        .task {
            guard appState.hasEnabledMailSource else { return }
            await appState.resolveMailAutomation(prompting: false)
        }
    }
}
