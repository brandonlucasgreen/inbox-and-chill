import Foundation
import MetricKit

/// Crashes the OS reports to the app itself, on the launch after they happen.
///
/// The second crash source, beside the `.ips` reader in `CrashHarvester`, and
/// the only one the App Store build has: a sandboxed app cannot read
/// `~/Library/Logs/DiagnosticReports`, which is where macOS writes its own
/// report. MetricKit delivers an `MXCrashDiagnostic` for the previous run —
/// exception type, signal, termination reason, and a call-stack tree per
/// thread — with no entitlement, no third-party code and no network. Decided
/// 2026-09-08; the alternatives and why they lost are in
/// docs/app-store-plan.md §4.
///
/// Three things about the payload that shape what is done with it:
///
/// - **Stacks arrive unsymbolicated.** Each frame carries the binary name,
///   its UUID, the runtime address and the offset into the binary's `__TEXT`
///   segment — never a symbol. So a MetricKit crash is titled "in `Inbox &
///   Chill` + 0x1234" rather than "in `AppState.handle(_:)`", and the export
///   keeps the offset so `atos` against the release dSYM can finish the job.
/// - **The date is the payload window, not the crash.** `timeStampEnd` says
///   when MetricKit closed the day's collection, not the minute the app died.
///   Good enough to order crashes and to tell "since you last dismissed";
///   not a timestamp to correlate against a log.
/// - **Delivery is asynchronous and once.** The subscriber can be called
///   seconds after launch, on a background queue, and the same crash is never
///   sent twice — so every payload is written to disk the moment it arrives.
///   The pane reads the file; `DiagnosticsRecorder` re-reads it when told.
///
/// The parsing is `nonisolated static` and pure (rule 6): hand it the JSON
/// `MXCallStackTree` produces and it hands back frames, so the tests need no
/// MetricKit and no crash. Xcode's *Debug › Simulate MetricKit Payload* is
/// the way to exercise the live subscriber; MetricKit does not deliver while
/// the app runs under the debugger otherwise.
enum MetricKitCrashes {
    // MARK: Call-stack tree

    /// `MXCallStackTree.jsonRepresentation()`: one entry per thread, each a
    /// chain that starts at **the frame that was executing** and walks
    /// outward through `subFrames` to the thread's entry point. That is the
    /// reverse of what the name "root" suggests, and it was settled by
    /// comparing a real payload with the `.ips` macOS wrote for the same
    /// crash (2026-09-08): the first build of this parser reversed the chain
    /// and put `dyld start` at frame 0. `threadAttributed` marks the thread
    /// the crash is charged to.
    private struct Tree: Decodable {
        var callStacks: [Stack]?
        var callStackPerThread: Bool?

        struct Stack: Decodable {
            var threadAttributed: Bool?
            var callStackRootFrames: [Frame]?
        }

        struct Frame: Decodable {
            var binaryUUID: String?
            var offsetIntoBinaryTextSegment: UInt64?
            var sampleCount: Int?
            var binaryName: String?
            var address: UInt64?
            var subFrames: [Frame]?
        }
    }

    /// The faulting thread's frames, innermost first (index 0 is where the
    /// crash happened), plus which thread that was. Empty frames when the
    /// tree is not the shape MetricKit documents.
    nonisolated static func frames(
        callStackTree data: Data
    ) -> (frames: [CrashReport.Frame], faultingThreadIndex: Int) {
        guard let tree = try? JSONDecoder().decode(Tree.self, from: data),
            let stacks = tree.callStacks, !stacks.isEmpty
        else { return ([], 0) }

        let faulting = stacks.firstIndex { $0.threadAttributed == true } ?? 0
        guard let roots = stacks[faulting].callStackRootFrames else {
            return ([], faulting)
        }

        // The root is already the crashing frame, so the chain is kept in
        // order and reads like Apple's report with frame 0 at the top. A tree
        // aggregated across samples could branch; a crash diagnostic is one
        // path per thread, and where there is a fork the first branch is the
        // one that ran.
        var chain: [Tree.Frame] = []
        var cursor = roots.first
        while let frame = cursor {
            chain.append(frame)
            cursor = frame.subFrames?.first
        }
        let frames = chain.enumerated().map { index, frame in
            CrashReport.Frame(
                index: index,
                image: frame.binaryName ?? "???",
                symbol: nil,
                symbolLocation: 0,
                address: frame.address ?? 0,
                imageOffset: frame.offsetIntoBinaryTextSegment)
        }
        return (frames, faulting)
    }

    // MARK: Names for the numbers

    /// Mach exception types, from `<mach/exception_types.h>`. MetricKit hands
    /// over the number; the pane and the issue title want the name every
    /// crash report prints.
    nonisolated static func exceptionName(_ type: Int) -> String {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 4: "EXC_EMULATION"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 7: "EXC_SYSCALL"
        case 8: "EXC_MACH_SYSCALL"
        case 9: "EXC_RPC_ALERT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        case 13: "EXC_CORPSE_NOTIFY"
        default: "EXC_\(type)"
        }
    }

    /// BSD signal numbers, from `<sys/signal.h>`.
    nonisolated static func signalName(_ signal: Int) -> String {
        switch signal {
        case 1: "SIGHUP"
        case 2: "SIGINT"
        case 3: "SIGQUIT"
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 7: "SIGEMT"
        case 8: "SIGFPE"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case 12: "SIGSYS"
        case 13: "SIGPIPE"
        case 14: "SIGALRM"
        case 15: "SIGTERM"
        default: "SIG\(signal)"
        }
    }

    // MARK: Assembling a report

    /// What one payload said about one crash, before it becomes a
    /// `CrashReport`. Plain values, so the conversion below is testable
    /// without an `MXCrashDiagnostic` — which cannot be constructed in a test.
    struct Diagnostic: Sendable {
        var callStackTree: Data
        var exceptionType: Int?
        var exceptionCode: Int?
        var signal: Int?
        var terminationReason: String?
        var virtualMemoryRegionInfo: String?
        /// `MXCrashDiagnosticObjectiveCExceptionReason.composedMessage`, when
        /// the crash was an Objective-C exception — the one sentence that
        /// names the bug outright.
        var objectiveCExceptionMessage: String?
        var buildVersion: String
        var osVersion: String
        var architecture: String
    }

    /// A `CrashReport` in the shape everything downstream already reads.
    ///
    /// - Parameters:
    ///   - date: the payload's `timeStampEnd` — the day, not the minute.
    ///   - fileName: where the raw payload was written, so the pane can
    ///     reveal it like it reveals an `.ips`.
    ///   - currentVersion: this build's marketing and build versions. The
    ///     payload names only the build number, so the marketing version is
    ///     filled in when the build matches and left as "?" when it does not
    ///     — a guess there would be exactly the wrong kind of helpful.
    nonisolated static func report(
        _ diagnostic: Diagnostic,
        date: Date,
        fileName: String,
        procName: String,
        bundleID: String,
        currentVersion: (short: String, build: String)
    ) -> CrashReport {
        let (frames, faulting) = frames(callStackTree: diagnostic.callStackTree)
        var reasons: [String] = []
        if let message = diagnostic.objectiveCExceptionMessage, !message.isEmpty {
            reasons.append(message)
        }
        if let reason = diagnostic.terminationReason, !reason.isEmpty {
            reasons.append(reason)
        }
        // The region info is several lines about memory near the fault; the
        // first is the one that says what kind of address it was.
        if let region = diagnostic.virtualMemoryRegionInfo?
            .split(separator: "\n").first.map(String.init), !region.isEmpty
        {
            reasons.append(region)
        }
        return CrashReport(
            fileName: fileName,
            date: date,
            appVersion: diagnostic.buildVersion == currentVersion.build
                ? currentVersion.short : "?",
            buildVersion: diagnostic.buildVersion,
            osVersion: "\(diagnostic.osVersion) — \(diagnostic.architecture)",
            procName: procName,
            bundleID: bundleID,
            exceptionType: diagnostic.exceptionType.map(exceptionName),
            signal: diagnostic.signal.map(signalName),
            subtype: diagnostic.exceptionCode.map { "exception code \($0)" },
            terminationIndicator: nil,
            terminationNamespace: nil,
            terminatedByProcess: nil,
            terminationReasons: reasons,
            faultingThreadIndex: faulting,
            frames: frames)
    }

    // MARK: Two sources, one list

    /// Crashes from both readers, newest first, with MetricKit's copy of a
    /// crash the `.ips` reader also saw dropped.
    ///
    /// In the direct build every crash arrives twice — once as the OS report,
    /// symbolicated and timed to the second, and once from MetricKit within a
    /// day. The two cannot be matched on time, because MetricKit's date is
    /// the collection window; they are matched on **build number and
    /// proximity**: a MetricKit report is a duplicate when an `.ips` report
    /// for the same build is dated inside the `window` before it. The `.ips`
    /// one is kept, because it is the better report.
    nonisolated static func merge(
        ips: [CrashReport], metricKit: [CrashReport],
        window: TimeInterval = 48 * 3600
    ) -> [CrashReport] {
        let fresh = metricKit.filter { report in
            !ips.contains { other in
                other.buildVersion == report.buildVersion
                    && other.date <= report.date
                    && report.date.timeIntervalSince(other.date) <= window
            }
        }
        return (ips + fresh).sorted { $0.date > $1.date }
    }
}

// MARK: - The file beside the store

/// Where MetricKit's reports are kept once they have arrived.
///
/// Delivery happens once, on a background queue, at some point after launch
/// — so the payload is written to disk immediately and everything else reads
/// the file. Two things are kept: the converted `CrashReport`s (one JSON
/// array, newest first, capped) and the raw payload each came from (one file
/// per payload, for the "Reveal" button and for anyone symbolicating by hand).
enum MetricKitCrashStore {
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "InboxAndChill/MetricKit")
    }

    static var defaultReportsURL: URL {
        defaultDirectory.appending(path: "crashes.json")
    }

    /// How many reports to keep. The pane shows one and the export the
    /// recent history; more than this is a pattern, not a report.
    static let limit = 10

    nonisolated static func load(url: URL = MetricKitCrashStore.defaultReportsURL) -> [CrashReport] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CrashReport].self, from: data)) ?? []
    }

    /// Prepends `reports`, trims, writes. Returns a sentence if the write
    /// failed — a crash report that silently fails to be kept is the
    /// rule-5 failure in a place built to prevent rule-5 failures.
    nonisolated static func append(
        _ reports: [CrashReport],
        url: URL = MetricKitCrashStore.defaultReportsURL
    ) -> String? {
        var all = reports.sorted { $0.date > $1.date } + load(url: url)
        all = Array(all.prefix(limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(all).write(to: url, options: .atomic)
            return nil
        } catch {
            return "Couldn't keep a crash report MetricKit delivered: "
                + "\(error.localizedDescription)"
        }
    }

    /// Writes one raw payload and returns the file name it was given.
    nonisolated static func writePayload(
        _ data: Data, receivedAt date: Date, index: Int,
        directory: URL = MetricKitCrashStore.defaultDirectory
    ) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "metrickit-\(formatter.string(from: date))-\(index).json"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }
}

// MARK: - The subscriber

/// Registers with `MXMetricManager` and turns whatever arrives into
/// `CrashReport`s on disk, then tells the recorder to look again.
///
/// The callback comes on MetricKit's own queue, so everything that touches
/// the payload happens there, synchronously, and only `Sendable` values cross
/// to the main actor. `MXDiagnosticPayload` is neither `Sendable` nor
/// constructible in a test, which is why the conversion goes through
/// `MetricKitCrashes.Diagnostic` first.
@MainActor
final class MetricKitCrashSource: NSObject, MXMetricManagerSubscriber {
    /// Called on the main actor with the reports just written, newest first.
    var onNewReports: (([CrashReport]) -> Void)?

    // Read from MetricKit's queue as well as the main actor, so not isolated.
    nonisolated private static let log = AppLog.logger(.diagnostics)

    func start() {
        MXMetricManager.shared.add(self)
        Self.log.notice("metrickit: subscribed for crash diagnostics")
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let procName = Bundle.main.executableURL?.lastPathComponent ?? "Inbox & Chill"
        let bundleID = Bundle.main.bundleIdentifier ?? "lol.bgreen.inboxandchill"
        let current = (short: Bundle.main.shortVersion, build: Bundle.main.buildVersion)
        var reports: [CrashReport] = []
        var index = 0
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                index += 1
                let fileName = MetricKitCrashStore.writePayload(
                    payload.jsonRepresentation(), receivedAt: Date(), index: index)
                let diagnostic = MetricKitCrashes.Diagnostic(
                    callStackTree: crash.callStackTree.jsonRepresentation(),
                    exceptionType: crash.exceptionType?.intValue,
                    exceptionCode: crash.exceptionCode?.intValue,
                    signal: crash.signal?.intValue,
                    terminationReason: crash.terminationReason,
                    virtualMemoryRegionInfo: crash.virtualMemoryRegionInfo,
                    objectiveCExceptionMessage: crash.exceptionReason?.composedMessage,
                    buildVersion: crash.metaData.applicationBuildVersion,
                    osVersion: crash.metaData.osVersion,
                    architecture: crash.metaData.platformArchitecture)
                reports.append(
                    MetricKitCrashes.report(
                        diagnostic, date: payload.timeStampEnd,
                        fileName: fileName ?? "metrickit-unsaved-\(index).json",
                        procName: procName, bundleID: bundleID,
                        currentVersion: current))
            }
        }
        guard !reports.isEmpty else {
            Self.log.notice("metrickit: \(payloads.count) payload(s), no crash diagnostics")
            return
        }
        if let problem = MetricKitCrashStore.append(reports) {
            Self.log.error("metrickit: \(problem, privacy: .public)")
        }
        Self.log.error(
            "metrickit: \(reports.count) crash diagnostic(s) delivered: \(CrashReportFile.signature(reports[0]), privacy: .public)")
        let delivered = reports
        Task { @MainActor in self.onNewReports?(delivered) }
    }

    /// Metrics are iOS-only; macOS delivers diagnostics alone. Present so the
    /// protocol is fully implemented, and empty because there is nothing to do.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {}
}
