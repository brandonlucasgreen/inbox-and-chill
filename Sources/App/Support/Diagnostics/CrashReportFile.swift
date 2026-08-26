import Foundation

/// Reading macOS `.ips` crash reports.
///
/// Everything here is `nonisolated static` and pure (rule 6): give it the text
/// of a report and it hands back a `CrashReport`, so the tests never need a
/// crash, a file system, or a running app.
///
/// **Why we read the OS's report rather than installing a crash handler.**
/// macOS already writes a full, symbolicated report for every crash into
/// `~/Library/Logs/DiagnosticReports`, and — measured on macOS 26.5, 2026-08-26
/// — that directory is readable with **no Full Disk Access and no
/// entitlement**. The controls were `~/Library/Mail` and `~/Library/Safari`,
/// both "Operation not permitted" in the same process that read a report end
/// to end. An in-process handler (PLCrashReporter, KSCrash) would re-derive
/// strictly less information — a signal handler cannot safely allocate — while
/// adding a binary to sign, notarize and re-sign nested.
///
/// **The file is two JSON documents, not one.** Line 1 is a short header
/// (`bundleID`, `app_version`, `os_version`, `timestamp`, `bug_type`); from
/// line 2 to the end is the body. Feeding the whole file to a JSON decoder
/// fails, which reads as a corrupt report rather than the wrong parse.
enum CrashReportFile {
    /// `bug_type` for a crash. The same directory holds hangs (`309` is the
    /// crash one; spins and hangs use other codes) and a pile of `.diag`
    /// analytics files that are not crashes at all.
    static let crashBugType = "309"

    // MARK: Parsing

    /// Decodes a `.ips` report. Returns nil when the text is not a crash
    /// report we can read — a `.diag` analytics file, a truncated write, a
    /// format change in a future macOS.
    ///
    /// - Parameters:
    ///   - fileName: recorded on the result so the UI can reveal the file.
    ///   - fallbackDate: used when the header timestamp is missing or is in a
    ///     format we do not recognise. Pass the file's modification date.
    nonisolated static func parse(
        ips text: String, fileName: String, fallbackDate: Date
    ) -> CrashReport? {
        let parts = text.split(
            separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let header = try? JSONDecoder().decode(
            Header.self, from: Data(parts[0].utf8)) else { return nil }
        guard let body = try? JSONDecoder().decode(
            Body.self, from: Data(parts[1].utf8)) else { return nil }

        let faulting = body.faultingThread ?? 0
        let threads = body.threads ?? []
        let rawFrames = faulting < threads.count ? (threads[faulting].frames ?? []) : []
        let images = body.usedImages ?? []

        let frames = rawFrames.enumerated().map { index, frame -> CrashReport.Frame in
            let image = frame.imageIndex.flatMap { i in
                i >= 0 && i < images.count ? images[i] : nil
            }
            let offset = UInt64(max(0, frame.imageOffset ?? 0))
            return CrashReport.Frame(
                index: index,
                image: image?.name ?? "???",
                symbol: frame.symbol,
                symbolLocation: frame.symbolLocation ?? 0,
                address: (image?.base ?? 0) &+ offset)
        }

        return CrashReport(
            fileName: fileName,
            date: header.timestamp.flatMap(date(fromHeaderTimestamp:)) ?? fallbackDate,
            appVersion: header.app_version ?? "",
            buildVersion: header.build_version ?? "",
            osVersion: header.os_version ?? "",
            // A bare executable has no bundle, so `app_name` can be absent
            // while `procName` in the body is always there.
            procName: body.procName ?? header.app_name ?? header.name ?? "",
            bundleID: header.bundleID,
            exceptionType: body.exception?.type,
            signal: body.exception?.signal,
            subtype: body.exception?.subtype,
            terminationIndicator: body.termination?.indicator,
            terminationNamespace: body.termination?.namespace,
            terminatedByProcess: body.termination?.byProc,
            terminationReasons: body.termination?.reasons ?? [],
            faultingThreadIndex: faulting,
            frames: frames)
    }

    /// True when this report belongs to us.
    ///
    /// Checks the bundle id when the report has one and falls back to the
    /// process name otherwise — a report for a *bare executable* carries no
    /// `bundleID` at all (measured: a crashed command-line probe on this Mac
    /// produced a report with `bundleID` absent and `procName` set), and the
    /// embedded `inchill` CLI is exactly that shape.
    nonisolated static func belongsToUs(
        _ report: CrashReport, bundleID: String, procNames: [String]
    ) -> Bool {
        if let reportBundle = report.bundleID, !reportBundle.isEmpty {
            return reportBundle == bundleID || reportBundle.hasPrefix(bundleID + ".")
        }
        return procNames.contains(report.procName)
    }

    // MARK: Rendering

    /// A one-line description, used as the pane's headline and as the GitHub
    /// issue title — so two of the same crash produce the same title and land
    /// on the same issue rather than two.
    nonisolated static func signature(_ report: CrashReport) -> String {
        // A dyld or codesigning failure names itself far better than any
        // backtrace can: the OS literally appends "terminated at launch;
        // ignore backtrace". A `SIGNAL` termination does not — its indicator
        // is "Segmentation fault: 11", which only restates the signal and
        // costs us the frame that actually says where. Measured against a
        // real report on 2026-08-26, which is how this was caught.
        if let indicator = report.terminationIndicator, !indicator.isEmpty,
           report.terminationNamespace != "SIGNAL" {
            return indicator
        }
        var head = report.exceptionType ?? "Crash"
        if let signal = report.signal, !signal.isEmpty, signal != head {
            head += " (\(signal))"
        }
        // Only *our* frame. Naming the topmost frame regardless would title
        // every crash "in mach_msg2_trap", which is true of the whole idle
        // main thread and says nothing.
        if let symbol = topmostOwnSymbol(report) {
            return "\(head) in \(symbol)"
        }
        if let killer = report.terminatedByProcess, !killer.isEmpty {
            return "\(head), sent by \(killer)"
        }
        return head
    }

    /// The first frame that is in our own binary, which is nearly always the
    /// interesting one — the frames above it are libsystem and the Swift
    /// runtime, identical across every crash of this shape.
    ///
    /// Returns nil rather than falling back to somebody else's frame: a crash
    /// with no frame of ours (an external kill, a watchdog) is a real and
    /// different thing, and a borrowed symbol would disguise it.
    nonisolated static func topmostOwnSymbol(_ report: CrashReport) -> String? {
        report.frames.first { $0.image == report.procName && $0.symbol != nil }?
            .symbol
    }

    /// The faulting thread, rendered the way Apple's own text crash reports
    /// render it. Frames with no symbol keep their image and address so they
    /// can still be resolved later with `atos` against the release dSYM.
    nonisolated static func backtrace(_ report: CrashReport) -> String {
        guard !report.frames.isEmpty else {
            return "(no frames recorded)"
        }
        let width = report.frames.map { $0.image.count }.max() ?? 0
        return report.frames.map { frame in
            let index = String(format: "%-3d", frame.index)
            let image = frame.image.padding(
                toLength: max(width, 8), withPad: " ", startingAt: 0)
            let address = String(format: "0x%016llx", frame.address)
            let symbol = frame.symbol.map { "\($0) + \(frame.symbolLocation)" }
                ?? "(no symbol)"
            return "\(index) \(image)  \(address)  \(symbol)"
        }
        .joined(separator: "\n")
    }

    // MARK: Redaction

    /// Strips anything secret-shaped before a report leaves the app.
    ///
    /// macOS already replaces the user's short name with `USER` in the paths
    /// it writes, so this is the second pass, not the only one: it covers what
    /// *we* add to the export — the app's own log lines, connector error
    /// strings, source settings — where a token can genuinely appear.
    ///
    /// Deliberately blunt. A redaction that misses is worse than one that
    /// over-matches, and the reader can always ask for the unredacted file.
    nonisolated static func redact(_ text: String) -> String {
        var out = text
        for (pattern, template) in redactions {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: template)
        }
        return out
    }

    /// Ordered: the specific token shapes first, so the generic
    /// `token=<anything>` rule cannot swallow a match and hide what it was.
    private nonisolated static let redactions: [(String, String)] = [
        // Slack user/bot/app tokens.
        ("xox[abeoprs]-[A-Za-z0-9-]{8,}", "xox?-‹redacted›"),
        // GitHub: classic PATs, OAuth/user/server/refresh tokens, fine-grained.
        ("gh[pousr]_[A-Za-z0-9]{16,}", "gh?_‹redacted›"),
        ("github_pat_[A-Za-z0-9_]{16,}", "github_pat_‹redacted›"),
        // Linear.
        ("lin_api_[A-Za-z0-9]{16,}", "lin_api_‹redacted›"),
        // Sentry auth tokens and DSNs.
        ("sntry[a-z]_[A-Za-z0-9_.\\-]{16,}", "sntry?_‹redacted›"),
        ("https://[0-9a-f]{16,}@[A-Za-z0-9.\\-]+/[0-9]+", "https://‹redacted›@sentry/‹id›"),
        // Anything presented as a bearer credential.
        ("(bearer\\s+)[A-Za-z0-9._\\-]{8,}", "$1‹redacted›"),
        // Generic `token: "…"` / `api_key=…` in JSON, query strings and logs.
        ("((?:token|secret|password|passwd|api[_-]?key|auth)\"?\\s*[:=]\\s*\"?)"
            + "[^\"\\s,;}&]{6,}", "$1‹redacted›"),
        // E-mail addresses: a mail source's error strings carry them.
        ("[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}", "‹email›"),
        // Any home directory macOS did not already anonymise. Runs last so the
        // rules above still see real paths.
        ("/Users/(?!USER/)[^/\\s\"]+", "~"),
    ]

    // MARK: Timestamps

    /// The header's own format: `2026-08-26 11:00:45.00 -0400`. Locale-fixed,
    /// because the report is written with a fixed format regardless of the
    /// user's region — reading it with the current locale is the same trap
    /// `AppleMailConnector` hit with `date received as string`.
    nonisolated static func date(fromHeaderTimestamp raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    // MARK: Wire shapes
    //
    // Decodable structs rather than dictionary walking, so an unexpected
    // report shape fails at one place with one nil instead of scattering
    // optional casts through the parse. Unknown keys are ignored, which is
    // most of the file: a real report carries ~50 top-level keys.

    private struct Header: Decodable {
        var app_name: String?
        var name: String?
        var app_version: String?
        var build_version: String?
        var bundleID: String?
        var os_version: String?
        var timestamp: String?
        var bug_type: String?
    }

    private struct Body: Decodable {
        var procName: String?
        var exception: Exception?
        var termination: Termination?
        var faultingThread: Int?
        var threads: [Thread]?
        var usedImages: [Image]?

        struct Exception: Decodable {
            var type: String?
            var signal: String?
            var subtype: String?
        }

        struct Termination: Decodable {
            var indicator: String?
            var namespace: String?
            var byProc: String?
            var reasons: [String]?
        }

        struct Thread: Decodable {
            var frames: [Frame]?
        }

        struct Frame: Decodable {
            var imageOffset: Int?
            var symbol: String?
            var symbolLocation: Int?
            var imageIndex: Int?
        }

        struct Image: Decodable {
            var name: String?
            var base: UInt64?
        }
    }

    /// Whether a report header says "this is a crash". Exposed so the
    /// harvester can skip non-crash reports without a second parse.
    nonisolated static func bugType(ips text: String) -> String? {
        guard let line = text.split(
            separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
            let header = try? JSONDecoder().decode(Header.self, from: Data(line.utf8))
        else { return nil }
        return header.bug_type
    }
}
