import SwiftUI

/// Purchase state, the Buy button and Restore — the store build's answer to
/// the direct build's `LicenseSection`. The trial itself needs no controls;
/// this is where its state is always readable and where the one purchase
/// happens. Restore is required by guideline 3.1.1 and is the only control
/// here that shows a sign-in sheet.
struct PurchaseSection: View {
    @Environment(AppState.self) private var appState

    private var license: LicenseController { appState.license }

    var body: some View {
        Section("Purchase") {
            stateLine

            if license.state != .licensed {
                LabeledContent("One-time purchase") {
                    Button(buyLabel) {
                        Task { await license.purchase() }
                    }
                    .disabled(license.product == nil || license.isPurchasing)
                }
                LabeledContent("Bought it already?") {
                    Button("Restore Purchase") {
                        Task { await license.restore() }
                    }
                    .disabled(license.isPurchasing)
                }
                Text(
                    "Restoring asks the App Store to sign in and looks up purchases made with that Apple Account."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Every failure lands here in words — never as a state that
            // silently looks like an ended trial (rule 5).
            if let pending = license.pendingMessage {
                Text(pending)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if license.state != .licensed, let problem = license.productProblem {
                Text(problem)
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

    private var buyLabel: String {
        if license.isPurchasing { return "Buying…" }
        if let price = license.priceLabel { return "Buy — \(price)" }
        return "Buy"
    }

    @ViewBuilder private var stateLine: some View {
        switch license.state {
        case .licensed:
            LabeledContent("Status") {
                Text("Purchased — thank you")
            }
        case .trialing(let daysLeft):
            LabeledContent("Status") {
                Text("Free trial — ^[\(daysLeft) day](inflect: true) left")
            }
            Text(
                "When the trial ends, syncing pauses until you buy. Your queue and settings stay put."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .expired:
            LabeledContent("Status") {
                Text("Trial ended — syncing is paused")
                    .foregroundStyle(.red)
            }
            Text(
                "Your queue and archive are untouched; new items just aren't being fetched. Buying turns syncing back on."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
