import SwiftUI

/// The trial, said out loud where triage happens.
///
/// Expiry pausing sync is the one state this app must never be quiet about:
/// a paused safety net that looks alive recreates exactly the dropped-things
/// failure the app exists to prevent (rule 5, loudest case). So the ended
/// state is a persistent red bar in the panel *and* the main window, and the
/// last three trial days get a quieter countdown so the end never lands as a
/// surprise. Neither is dismissible — the fix is a key or a purchase, both
/// one click away.
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
        background: Color, @ViewBuilder message: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                message()
                Spacer(minLength: 0)
                if let url = Licensing.purchaseURL {
                    Link("Buy — \(Licensing.price)", destination: url)
                        .font(.system(size: 11, weight: .semibold))
                }
                Button("Enter License Key") {
                    openSettings()
                    WindowActivation.focusSettings()
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background)
            Divider()
        }
    }
}
