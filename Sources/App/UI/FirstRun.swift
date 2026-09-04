import SwiftUI

/// The first minute, for someone who has just installed the app.
///
/// Until 2026-09-04 an empty queue said "You're all caught up ☺" whether
/// there were no items or no *sources* — so a fresh install looked finished
/// rather than unstarted, and nothing pointed at Settings. For the buyer
/// PLAN §2.1.11 describes, that first minute is the conversion point.
///
/// The policy is pure and the copy lives here, so the tests can pin both
/// without standing up SwiftData. Two sources need no account and no token
/// — Apple Mail and Apple Reminders — and they are offered first, by name,
/// because they are the ones that buyer can finish setting up.
enum FirstRun {
    /// The kinds a person can connect without a credential of any kind.
    static let zeroSetupKinds = ["appleMail", "reminders"]

    /// True when nothing but the built-in local source exists — enabled or
    /// not. Existence rather than `isEnabled`, so someone who has switched
    /// every source off on purpose is not greeted like a stranger.
    nonisolated static func needsFirstSource(kinds: [String]) -> Bool {
        !kinds.contains { $0 != "local" }
    }

    /// Open the panel once, on the very first launch, so the welcome is
    /// seen rather than sitting behind a menu bar icon nobody has noticed
    /// yet. Never again after that, and never for an install that already
    /// has a source — an upgrade is not a first run.
    nonisolated static func shouldOpenPanelOnLaunch(
        hasLaunchedBefore: Bool, needsFirstSource: Bool
    ) -> Bool {
        !hasLaunchedBefore && needsFirstSource
    }

    static let hasLaunchedKey = "firstRun.hasLaunched"

    static let title = "Welcome to Inbox & Chill"
    static let message =
        "Connect a source and everything waiting for you lands here — one queue, emptied from the keyboard."
    static let zeroSetupNote = "Mail and Reminders need no account or token."
}

/// What an empty queue shows before the first source exists. Used by the
/// panel and the main window, so the two cannot drift.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(FirstRun.title)
                .font(.system(size: 15, weight: .semibold))
            Text(FirstRun.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Add Apple Mail") { add("appleMail") }
                Button("Add Reminders") { add("reminders") }
            }
            .controlSize(.regular)
            .padding(.top, 4)
            Button("Add Another Source…") { add(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.system(size: 12))
            Text(FirstRun.zeroSetupNote)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 320)
        .multilineTextAlignment(.center)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FirstRun.title)
    }

    /// Lands in Settings › Sources with the add sheet open on that kind —
    /// the same route `LicenseNotice` takes to the License section.
    private func add(_ kind: String?) {
        appState.requestAddSource(kind: kind)
        openSettings()
        WindowActivation.focusSettings()
    }
}
