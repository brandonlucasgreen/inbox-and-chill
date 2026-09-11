import SwiftUI

/// The trial, said out loud where triage happens.
///
/// Expiry pausing sync is the one state this app must never be quiet about:
/// a paused safety net that looks alive recreates exactly the dropped-things
/// failure the app exists to prevent (rule 5, loudest case). So the ended
/// state is a persistent red bar in the panel *and* the main window, and the
/// last three trial days get a quieter countdown so the end never lands as a
/// surprise. Neither is dismissible — the fix is a purchase (or, in the
/// direct build, a key), one click away.
///
/// Compiled into both builds; only the buttons differ, because
/// `AppState.license` has the same surface in each (`priceLabel`, `state`).
/// The store build must never read the words "license key" — 2.4.5(vi) —
/// and `scripts/verify-bundle.sh --app-store` greps for the button title.
struct LicenseNotice: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Switched off: nothing about licensing reaches the queue at all.
        if !Licensing.isEnforced {
            EmptyView()
        } else {
            notice
        }
    }

    @ViewBuilder private var notice: some View {
        switch appState.license.state {
        case .notStarted:
            // Store build only: the user closed the welcome without pressing
            // Start. Nothing syncs until they do, and this is where it says so.
            bar(background: .orange.opacity(0.08), showsPurchase: false) {
                Text("Your free trial hasn't started yet, so nothing is syncing. Start it whenever you're ready — \(Licensing.trialDays) days, then a one-time purchase.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .expired:
            bar(background: .red.opacity(0.08)) {
                Text(
                    "Your free trial has ended, so syncing is paused. Nothing was deleted — your queue, archive and settings are all still here."
                )
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .trialing(let daysLeft) where daysLeft <= 3:
            bar(background: .orange.opacity(0.08)) {
                Text("Trial — ^[\(daysLeft) day](inflect: true) left.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private func bar(
        background: Color, showsPurchase: Bool = true,
        @ViewBuilder message: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                message()
                Spacer(minLength: 0)
                if !showsPurchase {
                    Button(FirstRun.startTrialButton) {
                        Task { await appState.license.startTrial() }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .disabled(appState.license.isPurchasing)
                } else {
                    purchaseButtons
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background)
            Divider()
        }
    }

    @ViewBuilder private var purchaseButtons: some View {
                #if !APP_STORE
                    if let url = Licensing.purchaseURL {
                        Link("Buy — \(Licensing.price)", destination: url)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Button("Enter License Key") {
                        openSettings()
                        WindowActivation.focusSettings()
                    }
                    .font(.system(size: 11))
                #else
                    // The store is the checkout: Buy runs StoreKit's own
                    // sheet. Until the price has loaded the button leads to
                    // Settings, where `PurchaseSection` says why it hasn't.
                    if let price = appState.license.priceLabel {
                        Button("Buy — \(price)") {
                            Task { await appState.license.purchase() }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .disabled(appState.license.isPurchasing)
                    } else {
                        Button("Buy…") {
                            openSettings()
                            WindowActivation.focusSettings()
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    Button("Restore Purchase") {
                        Task { await appState.license.restore() }
                    }
                    .font(.system(size: 11))
                    .disabled(appState.license.isPurchasing)
                #endif
    }
}
