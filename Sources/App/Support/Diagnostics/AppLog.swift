import Foundation
import OSLog

/// The app's one logging subsystem, and the categories under it.
///
/// This existed as a string literal repeated in seven files. It is collapsed
/// here for a reason beyond tidiness: `UnifiedLogReader` asks the unified log
/// for "everything this app wrote" with a predicate built from
/// `AppLog.subsystem`, so a call site that spells the subsystem differently
/// writes to a place the diagnostics export cannot find. One constant is what
/// makes that predicate honest.
///
/// **Log at `.notice` or above for anything a crash report should carry.**
/// `.debug` and `.info` are cheap because macOS may keep them in a memory
/// buffer and never write them to disk; a breadcrumb that evaporates when the
/// process dies is not a breadcrumb. `Logger.log(...)` — the default level —
/// persists, which is what the existing call sites use.
enum AppLog {
    static let subsystem = "lol.bgreen.inboxandchill"

    /// Categories, as a closed set rather than free strings, so the
    /// Diagnostics pane can group by one and `ProblemLog` can reuse them.
    enum Category: String, Codable, Sendable, CaseIterable {
        case appleMail = "apple-mail"
        case banners
        case claudeHooks = "claude-hooks"
        case claudeSession = "claude-session"
        case diagnostics
        case journal
        case keywordWatch = "keyword-watch"
        case launchAtLogin = "launch-at-login"
        case license
        case slackSeed = "slack-seed"
        case sync
        case updates

        /// How this reads in the Diagnostics pane and the exported report.
        var displayName: String {
            switch self {
            case .appleMail: "Apple Mail"
            case .banners: "Notifications"
            case .claudeHooks: "Agent hooks"
            case .claudeSession: "Claude session"
            case .diagnostics: "Diagnostics"
            case .journal: "Journal"
            case .keywordWatch: "Slack keyword watch"
            case .launchAtLogin: "Launch at login"
            case .license: "License"
            case .slackSeed: "Slack backfill"
            case .sync: "Sync"
            case .updates: "Updates"
            }
        }
    }

    static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
