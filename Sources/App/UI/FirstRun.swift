import SwiftData
import SwiftUI

/// The first minute, for someone who has just installed the app.
///
/// Until 2026-09-04 an empty queue said "You're all caught up ☺" whether
/// there were no items or no *sources* — so a fresh install looked finished
/// rather than unstarted, and nothing pointed at Settings. For the buyer
/// PLAN §2.1.11 describes, that first minute is the conversion point.
///
/// Three things Brandon asked for after walking it (2026-09-04):
///
/// - **A real welcome window on first launch**, not a state buried in the
///   panel: *"nothing popped up when I opened the app for the first time"*.
///   `WelcomeWindowView` is that window's content; `WelcomeWindowController`
///   opens it once, as an AppKit window the app presents itself, and never
///   again.
/// - **No featured sources.** Naming Mail and Reminders *"sells short the
///   depth of services I&C integrates with"* — so the welcome names the whole
///   roster and has one button, "Add Your First Source".
/// - **Nothing is pre-added.** The local coding-agents source used to be
///   created on first run; now every source, that one included, is added by
///   the user. So "no source yet" means exactly that.
///
/// The policy is pure and the copy lives here, so the tests can pin both
/// without standing up SwiftData.
enum FirstRun {
    /// True when no source of any kind exists. Existence rather than
    /// `isEnabled`, so someone who has switched every source off on purpose
    /// is not greeted like a stranger.
    nonisolated static func needsFirstSource(kinds: [String]) -> Bool {
        kinds.isEmpty
    }

    /// Show the welcome window on the very first launch, and only then.
    /// Never for an install that already has a source — an upgrade is not a
    /// first run. `forced` is the preview switch below, which shows it
    /// regardless so the window can be looked at on a Mac that is long past
    /// its first run.
    nonisolated static func shouldShowWelcomeWindow(
        hasLaunchedBefore: Bool, needsFirstSource: Bool, forced: Bool = false
    ) -> Bool {
        forced || (!hasLaunchedBefore && needsFirstSource)
    }

    static let hasLaunchedKey = "firstRun.hasLaunched"

    /// After saving a source, open the panel once — only when that source is
    /// the first one, so the arc that started with the welcome ends at the
    /// queue instead of in Settings. Editing, or adding a second source, does
    /// not pop the panel over what the user is doing.
    nonisolated static func shouldOpenQueueAfterSave(
        wasAdding: Bool, sourcesBefore: Int
    ) -> Bool {
        wasAdding && sourcesBefore == 0
    }

    /// `open -a "Inbox & Chill" --env INCHILL_SHOW_WELCOME=1` shows the
    /// welcome on any install, for design review and screenshots. It does not
    /// stamp or clear the first-run flag. Works in Release on purpose: the
    /// people looking at the window are running the installed build.
    static let previewEnvironmentKey = "INCHILL_SHOW_WELCOME"

    static let title = "Welcome to Inbox & Chill"
    static let message =
        "Connect a source and everything waiting for you lands here — one queue, emptied from the keyboard."
    static let addButton = "Add Your First Source"

    // MARK: The trial, on the welcome (store build)

    /// Guideline 3.1.1 asks that, before a trial starts, the app states its
    /// length, what stops when it ends, and what full use costs. Shown only
    /// where the mechanic is on (`Licensing.isEnforced`), i.e. the store
    /// build; the price is StoreKit's and may not have loaded yet, so the
    /// sentence stands without it.
    nonisolated static func trialDisclosure(price: String?) -> String {
        let cost = price.map { "a one-time \($0) purchase" } ?? "a one-time purchase"
        return
            "Free for \(Licensing.trialDays) days. After that, syncing pauses until \(cost) — your queue and settings stay put."
    }

    /// The trial starts on a press, not on launch (Brandon, 2026-09-10:
    /// *"much more user-friendly and standard"*). Screen one of the store
    /// build's welcome carries this button; screen two confirms the start
    /// and offers the first source. The direct build shows screen two only.
    static let startTrialButton = "Start Free Trial"
    static let trialStartedTitle = "Your free trial has started"

    /// Screen two's one sentence. The end date comes from the controller and
    /// is nil for a heartbeat between the press and the Keychain read, so
    /// the sentence stands without it.
    nonisolated static func trialStartedMessage(endsAt: Date?) -> String {
        guard let endsAt else {
            return "Everything is on for the next \(Licensing.trialDays) days. Now connect a source."
        }
        let day = endsAt.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return "Everything is on until \(day). Now connect a source."
    }

    /// The services, named, so the welcome says how far the app reaches
    /// rather than pointing at two of them. Read from the catalog so a new
    /// connector joins the sentence without anyone remembering to add it;
    /// the two generic kinds are folded into a closing clause.
    nonisolated static func sourceRoster(
        from descriptors: [ConnectorKindDescriptor]
    ) -> String {
        let named = descriptors
            .filter { $0.id != "local" && $0.id != "jsonPoller" && $0.id != "ntfy" }
            .map(\.displayName)
        guard !named.isEmpty else { return "Custom feeds and ntfy\(rosterTail)." }
        return named.joined(separator: ", ")
            + " — plus ntfy, any JSON feed\(rosterTail)."
    }

    /// The roster's closing clause names the local coding agents only where
    /// that source exists. The App Store build has no `inchill` and writes no
    /// hooks, so promising them on its welcome would be the copy lying.
    #if !APP_STORE
    nonisolated static let rosterTail = ", and your local coding agents"
    #else
    nonisolated static let rosterTail = ""
    #endif
}

/// What an empty queue shows before the first source exists. Used by the
/// panel, the main window and the welcome window, so the three cannot drift.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    /// Runs after Settings has been asked to open — the welcome window uses
    /// it to close itself.
    var afterAdd: (() -> Void)? = nil

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
            Text(FirstRun.sourceRoster(from: ConnectorCatalog.all))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if Licensing.isEnforced, appState.license.canStartTrial {
                // The store build's queue before Start was pressed: the
                // notice bar above says nothing is syncing; this says why
                // and offers the same button.
                Text(FirstRun.trialDisclosure(price: appState.license.priceLabel))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(FirstRun.startTrialButton) {
                    Task { await appState.license.startTrial() }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(appState.license.isPurchasing)
                .padding(.top, 6)
            } else {
                Button(FirstRun.addButton) { add() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: 340)
        .multilineTextAlignment(.center)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FirstRun.title)
    }

    /// Lands in Settings › Sources with the add sheet open — the same route
    /// `LicenseNotice` takes to the License section.
    private func add() {
        appState.requestAddSource(kind: nil)
        openSettings()
        // The welcome window is AppKit-hosted, outside the scene tree, where
        // the environment action may be inert — so also ask AppKit directly.
        WindowActivation.openSettings()
        WindowActivation.focusSettings()
        afterAdd?()
    }
}

/// The content of the first-launch window — the one branded surface in the
/// app (see `Brand`). Same copy as the in-queue `WelcomeView`, dressed: the
/// real app icon as the hero with a soft amber glow, the house tagline under
/// a wide Syne headline, Space Grotesk for the rest, and the guide's capsule
/// button in the one warm note. Dark blue in both appearances on purpose:
/// this is the brand's own ground, not a themed panel.
///
/// `WelcomeWindowController` owns the window and decides nothing; `AppState`
/// decides *whether* (see `wantsWelcomeWindow`). This view only knows how to
/// close itself: after the button, or once a source exists by any route.
struct WelcomeWindowView: View {
    var onDismiss: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @Query private var sources: [SourceConfig]

    /// Store build, before Start Free Trial: screen one. Everywhere else,
    /// screen two — which in the direct build is the whole welcome.
    private var offersTrial: Bool {
        Licensing.isEnforced && appState.license.canStartTrial
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.navyRaised, Brand.navy],
                startPoint: .top, endPoint: .bottom)
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
                    .shadow(color: Brand.amber.opacity(0.28), radius: 24, y: 6)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
                if offersTrial {
                    trialScreen
                } else {
                    sourceScreen
                }
                // A menu bar app that is not running is one that failed. The
                // welcome is the one moment to ask; Settings › General keeps
                // the same switch for later.
                Toggle(isOn: launchAtLogin) {
                    Text("Open at login")
                        .font(Brand.text(12))
                        .foregroundStyle(Brand.beigeDim)
                }
                .toggleStyle(.checkbox)
                .tint(Brand.amber)
                .padding(.top, 2)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 44)
            .padding(.top, 44)
            .padding(.bottom, 36)
            .animation(.default, value: offersTrial)
        }
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FirstRun.title)
        // The user added a source some other way (the panel, Settings
        // directly): the welcome has done its job.
        .onChange(of: sources.isEmpty) { _, isEmpty in
            if !isEmpty { onDismiss() }
        }
    }

    /// Screen one (store build only): what it is, what the trial is, one
    /// button. The 3.1.1 disclosure sits directly above the button so the
    /// terms are on screen when the press lands.
    @ViewBuilder private var trialScreen: some View {
        Text(FirstRun.title)
            .font(Brand.display(23))
            .foregroundStyle(Brand.beige)
        Text(Brand.tagline)
            .font(Brand.text(14))
            .foregroundStyle(Brand.beigeDim)
            .fixedSize(horizontal: false, vertical: true)
        Text(FirstRun.sourceRoster(from: ConnectorCatalog.all))
            .font(Brand.text(11.5))
            .foregroundStyle(Brand.beigeFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
        Text(FirstRun.trialDisclosure(price: appState.license.priceLabel))
            .font(Brand.text(11.5))
            .foregroundStyle(Brand.beigeFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
        Button(FirstRun.startTrialButton) {
            Task { await appState.license.startTrial() }
        }
        .buttonStyle(BrandCapsuleButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(appState.license.isPurchasing)
        .padding(.top, 8)
    }

    /// Screen two: the trial has started (store build) or there is no trial
    /// to speak of (direct build), and the first source is the next thing.
    @ViewBuilder private var sourceScreen: some View {
        // Only a running trial gets the "has started" header; a restored
        // purchase landing before the welcome closes gets the plain one.
        if Licensing.isEnforced, case .trialing = appState.license.state {
            Text(FirstRun.trialStartedTitle)
                .font(Brand.display(23))
                .foregroundStyle(Brand.beige)
            Text(FirstRun.trialStartedMessage(endsAt: appState.license.trialEndsAt))
                .font(Brand.text(14))
                .foregroundStyle(Brand.beigeDim)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(FirstRun.title)
                .font(Brand.display(23))
                .foregroundStyle(Brand.beige)
            Text(Brand.tagline)
                .font(Brand.text(14))
                .foregroundStyle(Brand.beigeDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(FirstRun.sourceRoster(from: ConnectorCatalog.all))
            .font(Brand.text(11.5))
            .foregroundStyle(Brand.beigeFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
        Button(FirstRun.addButton) { add() }
            .buttonStyle(BrandCapsuleButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, 8)
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { appState.launchAtLogin },
            set: { appState.launchAtLogin = $0 })
    }

    /// Same route as `WelcomeView.add`, then close.
    private func add() {
        appState.requestAddSource(kind: nil)
        openSettings()
        WindowActivation.openSettings()
        WindowActivation.focusSettings()
        onDismiss()
    }
}
