import Foundation

/// A note the app leaves saying "I am running", deleted when it quits
/// properly.
///
/// This is the only thing that can tell a *crash* from a *quit*, and it earns
/// its keep on the case macOS does not write a report for at all: force quit,
/// jetsam under memory pressure, a kernel panic, someone pulling the power.
/// Those leave the marker behind and no `.ips`, and without this the app would
/// report "no crashes" for a run that plainly did not end well.
struct RunMarker: Codable, Sendable, Equatable {
    var pid: Int32
    var version: String
    var build: String
    var startedAt: Date
}

enum RunMarkerStore {
    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "InboxAndChill/last-run.json")
    }

    /// Reads the previous run's marker, then writes this run's.
    ///
    /// Returns the marker only when it belongs to a *different* process, so
    /// this is safe to call more than once and cannot mistake the current run
    /// for a dead one.
    @discardableResult
    static func beginRun(
        url: URL = RunMarkerStore.defaultURL,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        version: String = Bundle.main.shortVersion,
        build: String = Bundle.main.buildVersion,
        now: Date = Date()
    ) -> RunMarker? {
        let previous = read(url: url).flatMap { $0.pid == pid ? nil : $0 }
        let marker = RunMarker(
            pid: pid, version: version, build: build, startedAt: now)
        write(marker, url: url)
        return previous
    }

    /// Called from `NSApplication.willTerminateNotification`. Its absence on
    /// the next launch is the whole signal.
    static func endRun(url: URL = RunMarkerStore.defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func read(url: URL = RunMarkerStore.defaultURL) -> RunMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RunMarker.self, from: data)
    }

    private static func write(_ marker: RunMarker, url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(marker) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Best effort by design: failing to write the marker must never stop
        // the app launching. The consequence of a missing marker is one
        // under-reported crash, and `CrashHarvester` still sees the `.ips`.
        try? data.write(to: url, options: .atomic)
    }

    /// How to describe a run that ended without a crash report to explain it.
    nonisolated static func unexplainedEndingSummary(_ marker: RunMarker) -> String {
        "Inbox & Chill \(marker.version) (\(marker.build)) stopped without "
        + "shutting down, and macOS didn't write a crash report. That usually "
        + "means it was force quit, ran out of memory, or the Mac lost power."
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var buildVersion: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}
