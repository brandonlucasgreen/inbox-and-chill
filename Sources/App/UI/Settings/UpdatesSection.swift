import SwiftUI

/// Updates, and whether they are actually working.
///
/// The toggle is the disclosure that this app talks to the network on its own
/// schedule — Sparkle's own "may I check for updates?" modal is declined in
/// `UpdateController` precisely so the answer lives here, where it can be
/// changed later, instead of in a dialog that appears once on the second
/// launch and never again.
struct UpdatesSection: View {
    @Environment(UpdateController.self) private var updates

    var body: some View {
        @Bindable var updates = updates
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                .disabled(self.updates.configurationProblem != nil)

            Text(
                "Once a day, in the background. You'll see what changed and be asked before anything is installed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            LabeledContent(lastCheckedLabel) {
                Button(self.updates.isChecking ? "Checking…" : "Check Now") {
                    self.updates.checkForUpdates()
                }
                .disabled(!self.updates.canCheck)
            }

            // A build with no signing key is the ordinary state of a clone
            // someone built themselves, so this is secondary rather than red:
            // it is a fact about the build, not something broken that they
            // need to go and fix right now.
            if let problem = self.updates.configurationProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // A failure *is* red. A check that silently stopped working is the
            // failure mode this whole section exists to prevent (rule 5).
            if let failure = self.updates.lastFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            LabeledContent("What changed") {
                Link(
                    "Release notes",
                    destination: URL(
                        string: "https://github.com/brandonlucasgreen/inbox-and-chill/releases")!)
            }
        }
    }

    private var lastCheckedLabel: String {
        guard let date = updates.lastCheck else { return "Never checked" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
