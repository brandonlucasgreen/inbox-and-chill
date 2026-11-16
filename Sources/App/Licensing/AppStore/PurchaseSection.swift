import SwiftUI

/// Purchase state, Start Free Trial, the Buy button and Restore. The direct
/// build has no counterpart (it is free; its Ko-fi link is in About). This is where the
/// trial's state is always readable and where the one purchase happens. Restore is required by guideline 3.1.1 and is the only control
/// here that shows a sign-in sheet.
///
/// **With `Licensing.isEnforced` off (since 2026-11-16) it is "Support":**
/// the app is free, there is no trial, and the same one-time purchase is
/// offered as an optional way to support it. It unlocks nothing.
struct PurchaseSection: View {
    @Environment(AppState.self) private var appState

    private var license: LicenseController { appState.license }

    var body: some View {
        Section(Licensing.isEnforced ? "Purchase" : "Support") {
            if Licensing.isEnforced {
                stateLine
            } else {
                supportLine
            }

            if Licensing.isEnforced, license.canStartTrial {
                LabeledContent("Free trial") {
                    Button(FirstRun.startTrialButton) {
                        Task { await license.startTrial() }
                    }
                    .disabled(license.isPurchasing)
                }
            }
            if license.state != .licensed {
                LabeledContent(Licensing.isEnforced ? "One-time purchase" : "Optional purchase") {
                    Button(buyLabel) {
                        Task { await license.purchase() }
                    }
                    .disabled(license.unlockProduct == nil || license.isPurchasing)
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

    /// The free app's line: either thanks, or what the purchase is for.
    @ViewBuilder private var supportLine: some View {
        if license.state == .licensed {
            LabeledContent("Status") {
                Text("Purchased — thank you")
            }
        } else {
            Text(
                "Inbox & Chill is free. If it saves you some time, the one-time purchase is an optional way to support it. It doesn't unlock anything."
            )
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var stateLine: some View {
        switch license.state {
        case .licensed:
            LabeledContent("Status") {
                Text("Purchased — thank you")
            }
        case .notStarted:
            LabeledContent("Status") {
                Text("Free trial not started — syncing is paused")
                    .foregroundStyle(.orange)
            }
            Text(FirstRun.trialDisclosure(price: license.priceLabel))
                .font(.caption)
                .foregroundStyle(.secondary)
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
