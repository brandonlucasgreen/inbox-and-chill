import Foundation

/// What one sweep of the crash-report directories found.
struct CrashHarvest: Sendable, Equatable {
    /// The most recent crash belonging to us that we had not already seen.
    var newest: CrashReport?
    /// Every crash of ours in the window, newest first — the pane shows one
    /// but the export carries the recent history.
    var reports: [CrashReport] = []
    /// Why the sweep could not see everything, as a sentence, or nil.
    ///
    /// Rule 5: "no crashes found" and "I was not able to look" must never
    /// render the same. If macOS ever puts these reports behind TCC, or moves
    /// them, this is what says so instead of a permanently reassuring
    /// "No crashes recorded."
    var problem: String?
    /// Files considered, for the export's "did this actually run" line.
    var scanned: Int = 0
}

/// Finds this app's crashes in the reports macOS already wrote.
///
/// The directory layout, verified on macOS 26.5 (2026-08-26): fresh reports
/// land in `~/Library/Logs/DiagnosticReports`, and macOS later moves them into
/// a `Retired` subdirectory — so a sweep that reads only the top level goes
/// blind on exactly the older crashes a user is most likely to be reporting.
/// Both are read, and both were readable with **no Full Disk Access**.
enum CrashHarvester {
    /// Where macOS writes them.
    static var defaultDirectories: [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports")
        return [root, root.appending(path: "Retired")]
    }

    /// Sweeps `directories` for our crash reports.
    ///
    /// - Parameters:
    ///   - directories: first entry is the primary one. It is expected to
    ///     exist — macOS creates it — so its absence is reported rather than
    ///     shrugged off. Later entries (`Retired`) are optional.
    ///   - newerThan: reports at or before this are skipped, so a crash is
    ///     announced once. Pass nil on a first run.
    ///   - limit: how many of our reports to keep, newest first.
    static func harvest(
        directories: [URL],
        bundleID: String,
        procNames: [String],
        newerThan: Date?,
        limit: Int = 5,
        fileManager: FileManager = .default
    ) -> CrashHarvest {
        var result = CrashHarvest()
        var problems: [String] = []
        var found: [CrashReport] = []

        for (index, directory) in directories.enumerated() {
            let isPrimary = index == 0
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: directory.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                if isPrimary {
                    problems.append(
                        "macOS's crash report folder isn't where it should be "
                        + "(\(directory.path)), so crashes can't be read.")
                }
                continue
            }

            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: directory.path)
            } catch {
                problems.append(
                    "Couldn't read \(directory.lastPathComponent): "
                    + "\(error.localizedDescription). Crashes can't be reported "
                    + "until that's resolved.")
                continue
            }

            for name in names where name.hasSuffix(".ips") {
                let url = directory.appending(path: name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    continue
                }
                result.scanned += 1
                guard CrashReportFile.bugType(ips: text)
                    == CrashReportFile.crashBugType else { continue }
                let modified = (try? fileManager.attributesOfItem(atPath: url.path))
                    .flatMap { $0[.modificationDate] as? Date } ?? Date.distantPast
                guard let report = CrashReportFile.parse(
                    ips: text, fileName: name, fallbackDate: modified) else { continue }
                guard CrashReportFile.belongsToUs(
                    report, bundleID: bundleID, procNames: procNames) else { continue }
                if let newerThan, report.date <= newerThan { continue }
                found.append(report)
            }
        }

        // macOS writes two files for one crash often enough to matter (a
        // `.000.ips` companion), and the same report can be seen in both the
        // live folder and `Retired` during the move. De-duplicate on the
        // crash itself, not the filename.
        var seen = Set<String>()
        result.reports = found
            .sorted { $0.date > $1.date }
            .filter { report in
                let key = "\(report.date.timeIntervalSince1970)-\(report.procName)"
                return seen.insert(key).inserted
            }
            .prefix(limit)
            .map { $0 }
        result.newest = result.reports.first
        result.problem = problems.isEmpty ? nil : problems.joined(separator: " ")
        return result
    }
}
