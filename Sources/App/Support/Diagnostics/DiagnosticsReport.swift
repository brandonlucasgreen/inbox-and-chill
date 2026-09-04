import Foundation

/// Everything the export knows, gathered in one place so the rendering below
/// can be a pure function (rule 6) and the tests never need a running app.
struct DiagnosticsSnapshot: Sendable {
    var generatedAt: Date
    var appVersion: String
    var buildVersion: String
    var osVersion: String
    var architecture: String
    var installPath: String
    /// From `UpdateController` — a build that cannot update is context for
    /// almost every "this was fixed weeks ago" report.
    var updateProblem: String?
    /// How many sources of each *kind* are configured. Kinds only: a source's
    /// name, URL and token are none of a bug report's business.
    var sourceKinds: [String: Int] = [:]
    var crash: CrashReport?
    var uncaughtException: UncaughtException?
    /// A previous run that ended with no crash report to explain it.
    var unexplainedEnding: RunMarker?
    var harvestProblem: String?
    var logWriteProblem: String?
    var problems: [Problem] = []
    var breadcrumbs = LogBreadcrumbs()
}

/// Turns a snapshot into the one block of text a user can paste anywhere.
enum DiagnosticsReport {
    static let repositoryURL = "https://github.com/brandonlucasgreen/inbox-and-chill"

    /// GitHub rejects very long URLs, and where it does not, the browser
    /// often does. 6 KB of body leaves room for the title and the rest of the
    /// query and stays inside every limit involved.
    static let issueBodyLimit = 6000

    // MARK: The report

    /// The full report. Every part is redacted on the way out — this is the
    /// single choke point, so a future section cannot forget to be.
    nonisolated static func text(_ snapshot: DiagnosticsSnapshot) -> String {
        var out: [String] = []

        out.append("Inbox & Chill diagnostics")
        out.append("Generated: \(iso(snapshot.generatedAt))")
        out.append("App: \(snapshot.appVersion) (\(snapshot.buildVersion))")
        out.append("macOS: \(snapshot.osVersion) — \(snapshot.architecture)")
        out.append("Installed at: \(snapshot.installPath)")
        if let updateProblem = snapshot.updateProblem {
            out.append("Updates: \(updateProblem)")
        }
        if !snapshot.sourceKinds.isEmpty {
            let kinds = snapshot.sourceKinds
                .sorted { $0.key < $1.key }
                .map { $0.value == 1 ? $0.key : "\($0.key) ×\($0.value)" }
                .joined(separator: ", ")
            out.append("Sources configured: \(kinds)")
        }

        out.append("")
        out.append("── Last crash ─────────────────────────────────────────")
        if let problem = snapshot.harvestProblem {
            out.append(problem)
        }
        if let crash = snapshot.crash {
            out.append(CrashReportFile.signature(crash))
            out.append("When: \(iso(crash.date))")
            out.append("Version at the time: \(crash.appVersion) (\(crash.buildVersion))")
            out.append("macOS at the time: \(crash.osVersion)")
            if let subtype = crash.subtype, !subtype.isEmpty {
                out.append("Detail: \(subtype)")
            }
            // Worth a line of its own: an app that was killed did not crash,
            // and the backtrace below is just wherever it happened to be.
            if let killer = crash.terminatedByProcess, !killer.isEmpty {
                out.append("Terminated by: \(killer)")
            }
            if !crash.terminationReasons.isEmpty {
                out.append("Termination:")
                out.append(contentsOf: crash.terminationReasons.map { "  \($0)" })
            }
            out.append("Report file: \(crash.fileName)")
            out.append("")
            out.append("Thread \(crash.faultingThreadIndex) (crashed):")
            out.append(CrashReportFile.backtrace(crash))
        } else if let marker = snapshot.unexplainedEnding {
            out.append(RunMarkerStore.unexplainedEndingSummary(marker))
            out.append("Last started: \(iso(marker.startedAt))")
        } else if snapshot.harvestProblem == nil {
            out.append("No crashes recorded.")
        }

        if let exception = snapshot.uncaughtException {
            out.append("")
            out.append("── Uncaught exception ─────────────────────────────────")
            out.append(ExceptionTrap.summary(exception))
            out.append("When: \(iso(exception.date))")
            out.append(contentsOf: exception.callStack)
        }

        out.append("")
        out.append("── Recent problems ────────────────────────────────────")
        if let logWriteProblem = snapshot.logWriteProblem {
            out.append(logWriteProblem)
        }
        if snapshot.problems.isEmpty {
            out.append("None recorded.")
        } else {
            for problem in snapshot.problems {
                var line = "\(iso(problem.date))  [\(problem.category.displayName)]"
                if let label = problem.sourceLabel { line += " \(label)" }
                out.append(line)
                out.append("  \(problem.summary)")
                if let detail = problem.detail, !detail.isEmpty {
                    out.append("  \(detail)")
                }
            }
        }

        out.append("")
        out.append("── App log ────────────────────────────────────────────")
        out.append(UnifiedLogReader.render(snapshot.breadcrumbs))

        return CrashReportFile.redact(out.joined(separator: "\n"))
    }

    // MARK: Filing it

    /// Title for a GitHub issue. The crash signature, so two reports of the
    /// same crash arrive with the same title and are visibly duplicates.
    nonisolated static func issueTitle(_ snapshot: DiagnosticsSnapshot) -> String {
        if let crash = snapshot.crash {
            return "Crash: \(CrashReportFile.signature(crash)) "
                + "(\(crash.appVersion))"
        }
        if let exception = snapshot.uncaughtException {
            return "Crash: \(exception.name) (\(snapshot.appVersion))"
        }
        if snapshot.unexplainedEnding != nil {
            return "Quit unexpectedly with no crash report (\(snapshot.appVersion))"
        }
        return "Diagnostics report (\(snapshot.appVersion))"
    }

    /// The issue body: a short human sentence, then the report in a fence.
    ///
    /// Truncated **loudly**. A silent cut is the failure mode this whole
    /// feature exists to avoid — the reader would have no way to know the
    /// backtrace they are looking at stops early.
    nonisolated static func issueBody(
        _ snapshot: DiagnosticsSnapshot, limit: Int = DiagnosticsReport.issueBodyLimit
    ) -> String {
        let preamble = """
            <!-- Say what you were doing when this happened; it is usually the \
            missing half. -->

            """
        let fenceOpen = "\n```\n"
        let fenceClose = "\n```\n"
        let overhead = preamble.count + fenceOpen.count + fenceClose.count
        let notice = "\n\n[… truncated. Use Export Diagnostics… in Settings › "
            + "Diagnostics for the full report.]"

        var report = text(snapshot)
        let room = max(0, limit - overhead)
        if report.count > room {
            report = String(report.prefix(max(0, room - notice.count))) + notice
        }
        return preamble + fenceOpen + report + fenceClose
    }

    /// A pre-filled "new issue" URL, or nil if it cannot be built.
    nonisolated static func issueURL(_ snapshot: DiagnosticsSnapshot) -> URL? {
        var components = URLComponents(string: repositoryURL + "/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: issueTitle(snapshot)),
            URLQueryItem(name: "body", value: issueBody(snapshot)),
            URLQueryItem(name: "labels", value: "bug"),
        ]
        return components?.url
    }

    /// A support e-mail with the subject filled in. The report itself is
    /// **not** in the body: `mailto:` bodies past a few kilobytes are
    /// truncated or refused by mail clients, so the caller copies the report
    /// to the clipboard and the body says where it is.
    nonisolated static func supportMailURL(_ snapshot: DiagnosticsSnapshot) -> URL? {
        var components = URLComponents(string: "mailto:\(SupportContact.email)")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: "Inbox & Chill — " + issueTitle(snapshot)),
            URLQueryItem(name: "body", value: supportMailBody),
        ]
        return components?.url
    }

    nonisolated static let supportMailBody =
        "The diagnostics report is on your clipboard — paste it below this line, and add what you were doing when it happened.\n\n"

    /// Default file name for Export Diagnostics…
    nonisolated static func fileName(_ snapshot: DiagnosticsSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "InboxAndChill-diagnostics-"
            + formatter.string(from: snapshot.generatedAt) + ".txt"
    }

    private nonisolated static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
