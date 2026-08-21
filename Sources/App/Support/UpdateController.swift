import AppKit
import Sparkle
import SwiftUI

/// In-app updates — and, more to the point, the reasons they might not be
/// happening.
///
/// Sparkle's own windows handle the actual update conversation, so this owns
/// only the three things Sparkle cannot do for us:
///
/// - **Say why nothing arrived.** A scheduled check that fails is silent by
///   design: no network, a feed that 404s, a signature that doesn't verify,
///   all look exactly like "you're up to date". That is this project's
///   recurring bug class (rule 5), so every failure lands in `lastFailure`
///   and the Updates section prints it.
/// - **Come to the front.** `LSUIElement` apps are not activated when a
///   window is ordered in, so Sparkle's "a new version is available" panel
///   opens *behind* whatever is frontmost and never becomes key — an update
///   that was found looks like an update that wasn't. Same two-step problem
///   `WindowActivation` solves for the settings and triage windows.
/// - **Refuse to pretend.** A build made from a clone that never generated a
///   signing key has no way to verify a download. Rather than let Sparkle
///   discover that mid-install and report a signature error — which reads as
///   "your download is corrupt" for what is really a build-time omission —
///   the updater is not started at all and Settings names the real problem.
@MainActor
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate
{
    // MARK: State the UI reads

    /// Why this build cannot check for updates, or nil if it can. Decided
    /// once at launch: a bundle with no signing key cannot grow one later.
    private(set) var configurationProblem: String?

    /// The last thing that went wrong, as a sentence, or nil if the last
    /// check was fine. Cleared at the start of every check so a fixed problem
    /// stops being reported.
    private(set) var lastFailure: String?

    /// True from "Check Now" until that check finishes, so the button can
    /// disable itself rather than queue up checks.
    private(set) var isChecking = false

    private(set) var lastCheck: Date?

    /// Mirrors Sparkle's own preference. Sparkle persists it in UserDefaults
    /// under `SUEnableAutomaticChecks`; this exists so SwiftUI has something
    /// observable to bind a Toggle to.
    var checksAutomatically: Bool = true {
        didSet { updater?.automaticallyChecksForUpdates = checksAutomatically }
    }

    var canCheck: Bool { updater != nil && !isChecking }

    // MARK: Sparkle

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }

    /// Set when an update window made us a regular app, so the Dock icon is
    /// put away again afterwards — but only if the triage window isn't the
    /// reason we're regular. See `restoreActivationPolicy`.
    private var raisedActivationPolicy = false

    override init() {
        super.init()

        if let problem = Self.configurationProblem(info: Bundle.main.infoDictionary) {
            configurationProblem = problem
            return
        }

        // `startingUpdater: false` and then starting it by hand, because
        // `start()` is the only call that reports a *configuration*
        // error, and Sparkle's own message for one names the problem better
        // than a guess from out here would.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)

        // Read Sparkle's stored preference before starting, so the toggle
        // shows what is actually in force rather than this property's default.
        checksAutomatically = controller.updater.automaticallyChecksForUpdates

        do {
            try controller.updater.start()
        } catch {
            // A failure here is a misconfigured bundle, not a transient
            // problem — surface it and leave `controller` nil so the UI
            // offers no buttons that cannot work.
            configurationProblem = Self.explain(error as NSError)
                ?? error.localizedDescription
            return
        }

        self.controller = controller
        controller.updater.updateCheckInterval = Self.checkInterval
        lastCheck = controller.updater.lastUpdateCheckDate
    }

    /// Once a day. Sparkle also checks shortly after launch when this has
    /// elapsed, which for a menu bar app that runs for weeks is the only
    /// check that ever fires.
    static let checkInterval: TimeInterval = 86_400

    // MARK: Actions

    /// The user asked. Sparkle shows its own progress and result windows,
    /// including "you're up to date", so this deliberately reports nothing
    /// itself beyond clearing the last failure.
    func checkForUpdates() {
        guard let updater else { return }
        lastFailure = nil
        isChecking = true
        updater.checkForUpdates()
    }

    // MARK: SPUUpdaterDelegate

    /// Sparkle would otherwise ask, on the second launch, whether it may
    /// check automatically. Answering it here instead keeps that decision in
    /// Settings next to every other toggle, where it can also be changed —
    /// a modal on launch can only be answered once.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    /// The one callback that fires at the end of every check, scheduled or
    /// manual, with the error if there was one.
    func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        isChecking = false
        lastCheck = updater.lastUpdateCheckDate
        lastFailure = error.flatMap { Self.explain($0 as NSError) }
    }

    // MARK: SPUStandardUserDriverDelegate

    func standardUserDriverWillShowModalAlert() { raiseActivationPolicy() }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        raiseActivationPolicy()
    }

    func standardUserDriverWillFinishUpdateSession() { restoreActivationPolicy() }

    // MARK: Activation

    private func raiseActivationPolicy() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            raisedActivationPolicy = true
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Put the Dock icon away again — unless the triage window is open, which
    /// is the other thing that makes this app regular. Reverting to
    /// `.accessory` underneath it would drop an open window out of the Dock
    /// and ⌘Tab, which is a worse bug than a lingering icon.
    private func restoreActivationPolicy() {
        guard raisedActivationPolicy else { return }
        raisedActivationPolicy = false
        let triageWindowOpen = NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible
        }
        guard !triageWindowOpen else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Pure helpers (rule 6)

    /// Nil when this build is able to check for updates at all.
    ///
    /// Both keys are written by `project.yml`'s `info.properties`. In practice
    /// it is the public key that goes missing: a clone that has never run
    /// `scripts/sparkle-keys.sh` builds and runs perfectly, and would only
    /// find out at install time that it cannot verify what it downloaded.
    nonisolated static func configurationProblem(info: [String: Any]?) -> String? {
        func value(_ key: String) -> String? {
            guard
                let string = info?[key] as? String,
                !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return string
        }

        if value("SUFeedURL") == nil {
            return """
                This build has no update feed (SUFeedURL is missing from its \
                Info.plist), so it can't look for new versions. Reinstall from \
                a release download, or rebuild after `xcodegen generate`.
                """
        }
        if value("SUPublicEDKey") == nil {
            return """
                This build has no update-signing key, so an update couldn't be \
                verified and automatic updates are switched off. That's \
                expected if you built it yourself: run `scripts/sparkle-keys.sh`, \
                paste the key into project.yml, and rebuild. Release downloads \
                already have one.
                """
        }
        return nil
    }

    /// A sentence for a Sparkle failure, or nil if it wasn't one.
    ///
    /// Two of Sparkle's aborts are not failures, and printing either in red
    /// would teach you to ignore the red text: `SUNoUpdateError` is the
    /// ordinary answer to "anything new?", and a cancelled or postponed
    /// install is a choice the user just made. Codes are from Sparkle's
    /// `SUErrors.h`; they are spelled out rather than imported because the
    /// generated Swift names for that `NS_ENUM` are not stable across
    /// Sparkle versions.
    nonisolated static func explain(_ error: NSError) -> String? {
        guard error.domain == SUSparkleErrorDomain else {
            // URL errors land here — no network, DNS, TLS, a 404 on the feed.
            // Their localizedDescription is already a decent sentence.
            return error.localizedDescription
        }
        switch error.code {
        case 1001, 4007, 4008:  // no update, install canceled, authorize later
            return nil
        case 1000, 1002, 1004:  // appcast parse / fetch / resume
            return """
                Couldn't read the update feed: \(error.localizedDescription) \
                If this persists, the release download on GitHub is always current.
                """
        case 3001, 3002:  // signature, validation
            return """
                An update was downloaded but failed its signature check, so it \
                was not installed: \(error.localizedDescription)
                """
        case 1, 2:  // no public key, insufficient signing
            return """
                This build can't verify updates: \(error.localizedDescription) \
                See scripts/sparkle-keys.sh.
                """
        default:
            return error.localizedDescription
        }
    }
}
