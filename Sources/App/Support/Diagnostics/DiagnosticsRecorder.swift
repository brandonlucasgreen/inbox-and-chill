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
/// machine only when the user presses Copy, Report on GitHub, or Export.
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
    /// Why the problem log is not being written, if it is not.
    private(set) var logWriteProblem: String?
    private(set) var recentProblems: [Problem] = []
    private(set) var isLoading = false

    /// True when there is something worth the user's attention. Drives the
    /// tab's attention dot.
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

    private static let log = AppLog.logger(.diagnostics)
    /// The newest crash we have already written to the problem log, so a
    /// crash is *recorded* once however often the pane is opened.
    private static let lastAnnouncedKey = "diagnosticsLastAnnouncedCrash"
    /// The newest crash the user has pressed Dismiss on, so the pane keeps
    /// *showing* a crash until they say they have read it.
    private static let dismissedKey = "diagnosticsDismissedCrash"

    private let problemLog: ProblemLog
    private let defaults: UserDefaults

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
        let previousRun = RunMarkerStore.beginRun()
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

        Task { await refresh(previousRun: previousRun) }
    }

    /// Re-reads crashes and problems. Cheap enough to call when the pane
    /// appears, so a crash that happened while Settings was open still shows.
    func refresh(previousRun: RunMarker? = nil) async {
        isLoading = true
        defer { isLoading = false }

        let bundleID = Bundle.main.bundleIdentifier ?? "lol.bgreen.inboxandchill"
        let procNames = ["Inbox & Chill", "inchill"]
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

        if let newest = harvest.newest {
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
            }
        }

        // A marker left behind with no crash report is the force-quit /
        // out-of-memory / lost-power case. Only report it when there is no
        // crash to explain the same run, or every crash would be announced
        // twice in two different voices.
        if crash == nil, uncaughtException == nil, let previousRun {
            unexplainedEnding = previousRun
            await problemLog.record(
                .diagnostics,
                RunMarkerStore.unexplainedEndingSummary(previousRun),
                at: previousRun.startedAt)
        }

        recentProblems = await problemLog.recent()
        logWriteProblem = await problemLog.currentWriteProblem()
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
    }

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
            logWriteProblem: logWriteProblem,
            problems: recentProblems,
            breadcrumbs: breadcrumbs)
    }

    /// Where the files live, for the pane's "Reveal" buttons.
    var problemLogURL: URL { ProblemLog.defaultURL }

    var crashReportURL: URL? {
        guard let crash else { return nil }
        // The harvester reads two directories and records only the file name,
        // so look in both rather than assuming the live one.
        return CrashHarvester.defaultDirectories
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
