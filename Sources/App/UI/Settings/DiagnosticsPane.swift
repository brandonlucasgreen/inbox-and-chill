import AppKit
import SwiftData
import SwiftUI

/// What broke, and how to tell someone about it.
///
/// A menu bar app that crashes leaves nothing behind but an icon that has
/// gone. This is where that becomes a fact the user can read and hand over —
/// and, just as much, where the non-fatal failures live: the connector that
/// has been erroring for two days behind a red dot nobody opened.
///
/// The one promise this pane makes, and keeps: **nothing is sent anywhere.**
/// Every report here is read from files already on the Mac, and leaves it only
/// when the user presses a button.
struct DiagnosticsPane: View {
    @Environment(DiagnosticsRecorder.self) private var diagnostics
    @Environment(UpdateController.self) private var updates
    @Query private var sources: [SourceConfig]

    @State private var showsBacktrace = false
    @State private var isWorking = false
    @State private var exportProblem: String?
    @State private var copied = false

    var body: some View {
        Form {
            crashSection
            problemsSection
            filesSection
        }
        .formStyle(.grouped)
        .task { await diagnostics.refresh() }
    }

    // MARK: Last crash

    @ViewBuilder
    private var crashSection: some View {
        Section("Last crash") {
            // Rule 5, applied to this pane itself: if crashes could not be
            // read, say so. "No crashes recorded" must never be what
            // "I couldn't look" renders as.
            if let problem = diagnostics.harvestProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let crash = diagnostics.crash {
                headline(
                    CrashReportFile.signature(crash),
                    detail: "\(crash.date.formatted(date: .abbreviated, time: .shortened))"
                        + " — version \(crash.appVersion) (\(crash.buildVersion))")

                if let subtype = crash.subtype, !subtype.isEmpty {
                    Text(subtype)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                ForEach(crash.terminationReasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                DisclosureGroup("Backtrace", isExpanded: $showsBacktrace) {
                    // Horizontal scrolling rather than wrapping: a wrapped
                    // backtrace is unreadable, and the frames are the point.
                    ScrollView([.horizontal, .vertical]) {
                        Text(CrashReportFile.backtrace(crash))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                }
            } else if let exception = diagnostics.uncaughtException {
                headline(
                    ExceptionTrap.summary(exception),
                    detail: exception.date.formatted(date: .abbreviated, time: .shortened))
            } else if let marker = diagnostics.unexplainedEnding {
                headline(
                    "Quit unexpectedly",
                    detail: RunMarkerStore.unexplainedEndingSummary(marker))
            } else if diagnostics.harvestProblem == nil {
                Text("No crashes recorded.")
                    .foregroundStyle(.secondary)
            }

            if diagnostics.hasSomethingToReport {
                actions
            }
        }
    }

    private func headline(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy Report") { copyReport() }
                    .disabled(isWorking)
                Button("Report on GitHub") { reportOnGitHub() }
                    .disabled(isWorking)
                if diagnostics.crashReportURL != nil {
                    Button("Reveal Crash Report") { revealCrashReport() }
                }
                Spacer()
                Button("Dismiss") { diagnostics.acknowledge() }
            }
            Text(
                "Report on GitHub opens a new issue with this report filled in. "
                + "Nothing is sent until you post it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: Recent problems

    @ViewBuilder
    private var problemsSection: some View {
        Section("Recent problems") {
            if let problem = diagnostics.logWriteProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if diagnostics.recentProblems.isEmpty {
                Text("Nothing has gone wrong since this was switched on.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics.recentProblems.prefix(20)) { problem in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.summary)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text(caption(for: problem))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }

            Text(
                "Errors the app has run into — a source that couldn't connect, "
                + "a journal it couldn't write. These are kept so a problem "
                + "that fixed itself can still be looked at afterwards."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caption(for problem: Problem) -> String {
        let when = problem.date.formatted(date: .abbreviated, time: .shortened)
        if let label = problem.sourceLabel, !label.isEmpty {
            return "\(problem.category.displayName) · \(label) · \(when)"
        }
        return "\(problem.category.displayName) · \(when)"
    }

    // MARK: Files

    @ViewBuilder
    private var filesSection: some View {
        Section("Diagnostics") {
            LabeledContent("Full report") {
                Button("Export Diagnostics…") { exportReport() }
                    .disabled(isWorking)
            }

            Text(
                "App and system versions, the last crash, recent problems, and "
                + "what the app logged around the time. Tokens, source names "
                + "and your home folder are stripped out before it's written."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Kept on this Mac") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [diagnostics.problemLogURL])
                }
            }

            if let exportProblem {
                Text(exportProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Actions

    private var sourceKinds: [String: Int] {
        sources.reduce(into: [:]) { counts, source in
            counts[source.kind, default: 0] += 1
        }
    }

    private func withSnapshot(_ body: @escaping (DiagnosticsSnapshot) -> Void) {
        isWorking = true
        Task {
            let snapshot = await diagnostics.snapshot(
                sourceKinds: sourceKinds,
                updateProblem: updates.lastFailure ?? updates.configurationProblem)
            body(snapshot)
            isWorking = false
        }
    }

    private func copyReport() {
        withSnapshot { snapshot in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                DiagnosticsReport.text(snapshot), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }

    private func reportOnGitHub() {
        withSnapshot { snapshot in
            // Built here from a fixed host and our own text, so there is no
            // untrusted scheme to police — unlike an item URL, which goes
            // through `AppState.openable`.
            guard let url = DiagnosticsReport.issueURL(snapshot) else {
                exportProblem = "Couldn't build the issue link for this report. "
                    + "Use Copy Report instead."
                return
            }
            exportProblem = nil
            NSWorkspace.shared.open(url)
        }
    }

    private func revealCrashReport() {
        guard let url = diagnostics.crashReportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportReport() {
        withSnapshot { snapshot in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = DiagnosticsReport.fileName(snapshot)
            panel.allowedContentTypes = [.plainText]
            panel.title = "Export Diagnostics"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try Data(DiagnosticsReport.text(snapshot).utf8)
                    .write(to: url, options: .atomic)
                exportProblem = nil
            } catch {
                // Never `try?` a write-through (rule 5): a save the user asked
                // for that quietly did nothing is the worst outcome here.
                exportProblem = "Couldn't write \(url.lastPathComponent): "
                    + error.localizedDescription
            }
        }
    }
}
