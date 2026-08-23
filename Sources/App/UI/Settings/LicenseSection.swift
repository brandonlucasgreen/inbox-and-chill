import SwiftUI

/// License state, key entry, and the way out of an ended trial. The trial
/// itself needs no controls — this is where its state is always readable,
/// and where a purchased key gets pasted.
struct LicenseSection: View {
    @Environment(AppState.self) private var appState
    @State private var keyField = ""

    private var license: LicenseController { appState.license }

    var body: some View {
        Section("License") {
            stateLine

            if license.state != .licensed {
                if let url = Licensing.purchaseURL {
                    LabeledContent("One-time purchase") {
                        Link("Buy Inbox & Chill — \(Licensing.price)",
                            destination: url)
                    }
                }
                HStack(spacing: 8) {
                    TextField(
                        "License key", text: $keyField,
                        prompt: Text("Paste the key from your purchase email"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .autocorrectionDisabled()
                        .onSubmit { activate() }
                    Button(license.isActivating ? "Activating…" : "Activate") {
                        activate()
                    }
                    .disabled(
                        license.isActivating
                            || keyField.trimmingCharacters(in: .whitespaces)
                                .isEmpty)
                }
                Text(
                    "Building from source is always free — the license covers the signed, auto-updating download and supports development."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                LabeledContent("Move to another Mac") {
                    Button("Deactivate on This Mac") {
                        Task { await license.deactivate() }
                    }
                }
                Text(
                    "Frees one of this key's activations so another Mac can use it. The key itself stays yours — paste it again any time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // A key the API explicitly rejected, and any activation failure,
            // both land here in words — never as a state that silently looks
            // like an ended trial (rule 5).
            if let reason = license.storedInvalidReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let problem = license.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var stateLine: some View {
        switch license.state {
        case .licensed:
            LabeledContent("Status") {
                Text(
                    license.keySuffix.map { "Licensed — key ending \($0)" }
                        ?? "Licensed")
            }
            if license.isTestModeKey {
                Text(
                    "This is a Lemon Squeezy test-mode key. It unlocks the app exactly like a real one — fine for checking the flow, not a real purchase."
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        case .trialing(let daysLeft):
            LabeledContent("Status") {
                Text("Free trial — ^[\(daysLeft) day](inflect: true) left")
            }
        case .expired:
            LabeledContent("Status") {
                Text("Trial ended — syncing is paused")
                    .foregroundStyle(.red)
            }
            Text(
                "Your queue and archive are untouched; new items just aren't being fetched. A license turns syncing back on."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func activate() {
        let key = keyField
        Task {
            await license.activate(key: key)
            if license.state == .licensed { keyField = "" }
        }
    }
}
