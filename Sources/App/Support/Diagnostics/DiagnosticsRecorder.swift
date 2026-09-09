import AppKit
import Foundation
import SwiftUI

/// What broke, and what the app was doing at the time.
///
/// The app's recurring bug class is a failure the user cannot see (rule 5).
/// Until now that applied to the app itself: a crash left nothing but a menu
/// bar icon that had gone, and a connector failure left a red dot whose reason
/// disappeared with the Settings window. This owns the other half — a crash
/// the user can read, and an error history that survives a restart.
///
/// **Nothing here sends anything anywhere.** The reports are read from files
/// macOS already wrote and written to files beside the store; they leave the
/// machine only when the user presses Copy, Report on GitHub, Email Support,
/// or Export — or answers "Send Report…" to the prompt after a crash.
///
/// Two crash sources feed it. The direct build reads macOS's own `.ips`
/// reports (`CrashHarvester`) and also subscribes to MetricKit; the App Store
/// build, sandboxed, cannot see the `.ips` directory and has MetricKit alone
/// (`MetricKitCrashes`). Both lists meet in `refresh`, where the `.ips` copy of
/// a crash MetricKit also reported wins.
///
/// Created at App scope beside `UpdateController`, for the same reason: it
/// installs process-wide handlers at launch and must outlive any one window.
@MainActor
@Observable
final class DiagnosticsRecorder {
    // MARK: What the pane reads

    /// The most recent crash we have not already shown, if any.
    private(set) var crash: CrashReport?
    /// An Objective-C exception recorded on the way down, if any.
    private(set) var uncaughtException: UncaughtException?
    /// A previous run that ended abruptly with no crash report to explain it.
    private(set) var unexplainedEnding: RunMarker?
    /// Why crashes could not be read, if they could not.
    private(set) var harvestProblem: String?
    /// Why this build reads crashes the way it does, when that needs saying.
    /// A fact about the build rather than a fault: rendered secondary, never
    /// red. Nil in the direct build; the sandbox sentence in the store build.
    private(set) var crashSourceNote: String?
    /// Why the problem log is not being written, if it is not.
    private(set) var logWriteProblem: String?
    private(set) var recentProblems: [Problem] = []
    private(set) var isLoading = false

    /// True when there is something worth the user's attention. Drives the
    /// tab's attention dot. The source note is deliberately not in here.
    var hasSomethingToReport: Bool {
        crash != nil || uncaughtException != nil || unexplainedEnding != nil
            || harvestProblem != nil || logWriteProblem != nil
    }

    /// True when this process was launched by XCTest — which is how Swift
    /// Testing runs under `xcodebuild test` too.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    // Read from a detached task as well as the main actor, so not isolated.
    nonisolated private static let log = AppLog.logger(.diagnostics)
    /// The newest crash we have already written to the problem log, so a
    /// crash is *recorded* once however often the pane is opened.
    private static let lastAnnouncedKey = "diagnosticsLastAnnouncedCrash"
    /// The newest crash the user has pressed Dismiss on, so the pane keeps
    /// *showing* a crash until they say they have read it.
    private static let dismissedKey = "diagnosticsDismissedCrash"

    private let problemLog: ProblemLog
    private let defaults: UserDefaults
    private let metricKit = MetricKitCrashSource()

    /// The marker the previous run left behind, kept because MetricKit can
    /// deliver the crash that explains it seconds after the first `refresh`.
    private var previousRun: RunMarker?
    /// The unexplained ending is written to the problem log once per launch,
    /// however many times `refresh` runs.
    private var unexplainedEndingRecorded = false

    init(problemLog: ProblemLog = .shared, defaults: UserDefaults = .standard) {
        self.problemLog = problemLog
        self.defaults = defaults
    }

    // MARK: Launch

    /// Installs the handlers and reads what the last run left behind.
    ///
    /// Split from `init` because it does file IO: a menu bar app's launch is
    /// the one moment the user is watching the icon appear.
    func start() {
        // `xcodebuild test` runs the *app* as the test host and then kills it,
        // which leaves a run marker behind and looks exactly like a force
        // quit — so a plain test run used to write a false "quit
        // unexpectedly" into the developer's own live diagnostics log, and
        // the Debug and Release builds share that one file. An app under test
        // is not a run worth recording.
        guard !Self.isRunningTests else { return }

        ExceptionTrap.install()
        previousRun = RunMarkerStore.beginRun()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            // The marker's *absence* is what says "this quit was deliberate".
            RunMarkerStore.endRun()
        }

        uncaughtException = ExceptionTrap.takePrevious()
        if let uncaughtException {
            Self.log.error(
                "previous run ended in an uncaught exception: \(ExceptionTrap.summary(uncaughtException), privacy: .public)")
        }

        // MetricKit delivers on its own schedule, after launch, on its own
        // queue; the source writes what arrives to disk and this re-reads.
        metricKit.onNewReports = { [weak self] _ in
            Task { await self?.refresh() }
        }
        metricKit.start()

        // One line, once, so the export's "only this run's lines" note can be
        // checked against what the process actually got at launch.
        Task.detached(priority: .utility) {
            let availability = UnifiedLogReader.availability()
            Self.log.notice("log store: \(availability.description, privacy: .public)")
        }

        Task { await refresh() }
    }

    /// Re-reads crashes and problems. Cheap enough to call when the pane
    /// appears, so a crash that happened while Settings was open still shows.
    func refresh() async {
        isLoading = true

        let bundleID = Bundle.main.bundleIdentifier ?? "lol.bgreen.inboxandchill"
        let procNames = ["Inbox & Chill", "inchill"]

        #if !APP_STORE
        // Deliberately unfiltered by date. Filtering the *sweep* meant a
        // crash was visible for exactly one launch and then disappeared —
        // which is fine for a notification and wrong for a pane whose job is
        // to still have the evidence when someone finally goes looking.
        // "Have I recorded this?" and "has the user read this?" are two
        // separate questions, and they get two separate marks below.
        let harvest = await Task.detached(priority: .utility) {
            CrashHarvester.harvest(
                directories: CrashHarvester.defaultDirectories,
                bundleID: bundleID,
                procNames: procNames,
                newerThan: nil)
        }.value
        harvestProblem = harvest.problem
        if let problem = harvest.problem {
            Self.log.error("crash harvest: \(problem, privacy: .public)")
        }
        let ipsReports = harvest.reports
        #else
        // The sandbox redirects `~/Library` into the container, so the OS's
        // crash-report folder is not merely unreadable but absent. Sweeping
        // it would report "the folder isn't where it should be", which is
        // true and unhelpful; saying what this build reads instead is the
        // rule-5 version.
        _ = (bundleID, procNames)
        crashSourceNote = Self.sandboxCrashSourceNote
        let ipsReports: [CrashReport] = []
        #endif

        let metricKitReports = await Task.detached(priority: .utility) {
            MetricKitCrashStore.load()
        }.value
        let reports = MetricKitCrashes.merge(ips: ipsReports, metricKit: metricKitReports)

        var newlyAnnounced: CrashReport?
        if let newest = reports.first {
            let dismissed = defaults.object(forKey: Self.dismissedKey) as? Date
            crash = (dismissed.map { newest.date > $0 } ?? true) ? newest : nil

            let announced = defaults.object(forKey: Self.lastAnnouncedKey) as? Date
            if announced.map({ newest.date > $0 }) ?? true {
                defaults.set(newest.date, forKey: Self.lastAnnouncedKey)
                Self.log.error(
                    "previous run crashed: \(CrashReportFile.signature(newest), privacy: .public)")
                await problemLog.record(
                    .diagnostics,
                    "Inbox & Chill quit unexpectedly: \(CrashReportFile.signature(newest))",
                    detail: "Crash report \(newest.fileName), version \(newest.appVersion) (\(newest.buildVersion))",
                    at: newest.date)
                newlyAnnounced = newest
            }
        }

        // A marker left behind with no crash report is the force-quit /
        // out-of-memory / lost-power case. Only report it when there is no
        // crash to explain the same run, or every crash would be announced
        // twice in two different voices. A crash arriving later (MetricKit)
        // explains the marker after the fact, so the marker steps aside.
        if crash != nil || uncaughtException != nil {
            unexplainedEnding = nil
        } else if let previousRun, !unexplainedEndingRecorded {
            unexplainedEndingRecorded = true
            unexplainedEnding = previousRun
            await problemLog.record(
                .diagnostics,
                RunMarkerStore.unexplainedEndingSummary(previousRun),
                at: previousRun.startedAt)
        }

        recentProblems = await problemLog.recent()
        logWriteProblem = await problemLog.currentWriteProblem()
        isLoading = false

        // Last, and only for a crash seen for the first time: the offer to
        // send it. After `isLoading` is cleared because the alert is modal.
        if let newlyAnnounced {
            offerToSend(newlyAnnounced)
        }
    }

    /// Dismisses what is currently shown. The files stay, and so does the
    /// entry in Recent problems; this only stops the pane leading with
    /// something the user has now read. Persisted, so it stays dismissed.
    func acknowledge() {
        if let crash {
            defaults.set(crash.date, forKey: Self.dismissedKey)
        }
        crash = nil
        uncaughtException = nil
        unexplainedEnding = nil
        previousRun = nil
    }

    // MARK: The prompt after a crash

    /// "Inbox & Chill quit unexpectedly last time. Send the report?"
    ///
    /// Decided in docs/app-store-plan.md §4: the app has no crash *pipeline*
    /// — no SDK, no endpoint, and never an ntfy topic baked into the binary
    /// — so the only way a crash reaches anyone is the user choosing to send
    /// it. Asking once, at the relaunch, is what makes that choice available
    /// to someone who will never open Settings › Diagnostics. Once per crash,
    /// gated by the same "have I recorded this?" mark as the problem-log line.
    private func offerToSend(_ crash: CrashReport) {
        guard !Self.isRunningTests else { return }
        // An LSUIElement app is not activated when a window appears, so the
        // alert would open behind whatever is frontmost and never be seen.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = CrashPrompt.title
        alert.informativeText = CrashPrompt.body(signature: CrashReportFile.signature(crash))
        alert.addButton(withTitle: CrashPrompt.sendButton)
        alert.addButton(withTitle: CrashPrompt.laterButton)
        let response = alert.runModal()
        let chose = response == .alertFirstButtonReturn
        Self.log.notice("crash prompt answered: \(chose ? "send" : "later", privacy: .public)")
        guard chose else { return }
        Task {
            if let problem = await emailSupport() {
                ProblemLog.note(.diagnostics, problem)
            }
        }
    }

    /// Copies the report to the clipboard and opens a message to support with
    /// the subject filled in. Returns a sentence if the message could not be
    /// opened — the report is on the clipboard either way, and the sentence
    /// says so. The body says the report is on the clipboard rather than
    /// carrying it: `mailto:` bodies past a few kilobytes are truncated or
    /// refused by mail clients (`DiagnosticsReport.supportMailURL`).
    func emailSupport(
        sourceKinds: [String: Int] = [:], updateProblem: String? = nil
    ) async -> String? {
        let snapshot = await snapshot(sourceKinds: sourceKinds, updateProblem: updateProblem)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            DiagnosticsReport.text(snapshot), forType: .string)
        guard let url = DiagnosticsReport.supportMailURL(snapshot) else {
            return "Couldn't open a mail message. The report is on your "
                + "clipboard — paste it into an e-mail to \(SupportContact.email)."
        }
        NSWorkspace.shared.open(url)
        return nil
    }

    /// What the store build says instead of sweeping a folder it cannot see.
    nonisolated static let sandboxCrashSourceNote =
        "This copy runs in the App Sandbox, so macOS's own crash reports are out "
        + "of its reach. Crashes reach it through MetricKit instead, usually on "
        + "the launch after they happen — so a crash shows up here once the app "
        + "has been opened again."

    // MARK: Recording

    /// Records a problem and refreshes the list the pane is showing.
    func record(
        _ category: AppLog.Category,
        _ summary: String,
        sourceID: String? = nil,
        sourceLabel: String? = nil,
        detail: String? = nil
    ) {
        Task {
            await problemLog.record(
                category, summary, sourceID: sourceID,
                sourceLabel: sourceLabel, detail: detail)
            recentProblems = await problemLog.recent()
            logWriteProblem = await problemLog.currentWriteProblem()
        }
    }

    // MARK: Export

    /// Gathers everything into one snapshot. Reads the unified log, which is
    /// slow, so it is `async` and off the main actor.
    func snapshot(
        sourceKinds: [String: Int] = [:], updateProblem: String? = nil
    ) async -> DiagnosticsSnapshot {
        let crash = self.crash
        let breadcrumbs = await Task.detached(priority: .userInitiated) {
            UnifiedLogReader.breadcrumbs(before: crash?.date ?? Date())
        }.value

        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsSnapshot(
            generatedAt: Date(),
            appVersion: Bundle.main.shortVersion,
            buildVersion: Bundle.main.buildVersion,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: Self.architecture,
            installPath: Bundle.main.bundleURL.path(percentEncoded: false),
            updateProblem: updateProblem,
            sourceKinds: sourceKinds,
            crash: crash,
            uncaughtException: uncaughtException,
            unexplainedEnding: unexplainedEnding,
            harvestProblem: harvestProblem,
            crashSourceNote: crashSourceNote,
            logWriteProblem: logWriteProblem,
            problems: recentProblems,
            breadcrumbs: breadcrumbs)
    }

    /// Where the files live, for the pane's "Reveal" buttons.
    var problemLogURL: URL { ProblemLog.defaultURL }

    var crashReportURL: URL? {
        guard let crash else { return nil }
        // Only the file name is recorded, so look everywhere a report can
        // come from: both `.ips` folders (direct build) and MetricKit's.
        var directories = [MetricKitCrashStore.defaultDirectory]
        #if !APP_STORE
        directories = CrashHarvester.defaultDirectories + directories
        #endif
        return directories
            .map { $0.appending(path: crash.fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `arm64` / `x86_64`, and whether we are under Rosetta — a translated
    /// build is worth knowing about before reading any backtrace.
    private static var architecture: String {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let known = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return known && translated == 1 ? "\(arch) (under Rosetta)" : arch
    }
}

/// The copy for the after-crash prompt, kept pure so the tests can pin it.
enum CrashPrompt {
    static let title = "Inbox & Chill quit unexpectedly last time."
    static let sendButton = "Send Report…"
    static let laterButton = "Not Now"

    /// Names the crash, then says exactly what "send" does and does not do —
    /// the report goes to the clipboard and a message opens; nothing leaves
    /// until the user presses Send in their mail app.
    nonisolated static func body(signature: String) -> String {
        """
        \(signature)

        Send the report? It's copied to your clipboard and a message to \
        \(SupportContact.email) opens with the subject filled in. Nothing is \
        sent until you press Send there. Settings › Diagnostics has the same \
        report, and the details, whenever you want them.
        """
    }
}
