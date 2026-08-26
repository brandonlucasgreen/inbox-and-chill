import Foundation
import OSLog

/// One line the app wrote to the unified log.
struct AppLogEntry: Sendable, Equatable {
    var date: Date
    var category: String
    var level: String
    var message: String
}

/// What the app itself was saying in the minutes before a crash.
struct LogBreadcrumbs: Sendable {
    var entries: [AppLogEntry] = []
    /// Why the log could not be read, or nil. Rule 5: an empty breadcrumb
    /// list and an unreadable log must not render the same.
    var problem: String?
}

/// Reads this app's own entries back out of the unified log.
///
/// This is why the app needs no bespoke file logger for breadcrumbs: macOS is
/// already keeping them, across process restarts, including the run that
/// crashed. Measured on macOS 26.5 (2026-08-26) from a **Developer ID,
/// hardened-runtime** binary carrying only the apple-events entitlement:
/// `OSLogStore.local()` returned 105 entries written by *previous* processes
/// of the app.
///
/// Two things that look like they should be needed and are not:
///
/// - **No entitlement.** Apple's documentation names
///   `com.apple.logging.local-store`; that is stale for an unsandboxed app run
///   by an admin user, and declaring an entitlement we cannot be granted would
///   break signing rather than help.
/// - **No custom log file.** `AppLog` already routes everything through one
///   subsystem, so the predicate below is the whole implementation.
///
/// The catch worth knowing: `.debug` and `.info` entries may live only in a
/// memory buffer and never reach disk, so a breadcrumb logged at those levels
/// dies with the process. `AppLog`'s doc comment says to log at the default
/// level or above; this is why.
enum UnifiedLogReader {
    /// How far back to look. Long enough to cover a hung poll, short enough
    /// that reading it is not a scan of the whole log.
    static let defaultWindow: TimeInterval = 30 * 60
    static let defaultLimit = 200

    /// Entries this app wrote, oldest first, ending at `before`.
    ///
    /// Blocking and potentially slow — the store is scanned, not indexed —
    /// so call it off the main actor.
    static func breadcrumbs(
        subsystem: String = AppLog.subsystem,
        before: Date = Date(),
        window: TimeInterval = UnifiedLogReader.defaultWindow,
        limit: Int = UnifiedLogReader.defaultLimit
    ) -> LogBreadcrumbs {
        var result = LogBreadcrumbs()
        do {
            let store = try OSLogStore.local()
            let start = store.position(date: before.addingTimeInterval(-window))
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let entries = try store.getEntries(
                with: [], at: start, matching: predicate)
            var collected: [AppLogEntry] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                guard log.date <= before else { break }
                collected.append(AppLogEntry(
                    date: log.date,
                    category: log.category,
                    level: name(for: log.level),
                    message: log.composedMessage))
            }
            // Keep the *end* of the window: the lines nearest the crash are
            // the ones worth having.
            result.entries = collected.suffix(limit).map { $0 }
        } catch {
            result.problem = "Couldn't read the app's own log: "
                + "\(error.localizedDescription)"
        }
        return result
    }

    /// Renders breadcrumbs for the export. Pure, so it is tested directly.
    nonisolated static func render(_ breadcrumbs: LogBreadcrumbs) -> String {
        if let problem = breadcrumbs.problem {
            return problem
        }
        guard !breadcrumbs.entries.isEmpty else {
            return "(the app wrote nothing to the log in this window)"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return breadcrumbs.entries.map { entry in
            "\(formatter.string(from: entry.date))  \(entry.level.uppercased())  "
            + "[\(entry.category)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    private static func name(for level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "?"
        @unknown default: "?"
        }
    }
}
