import Foundation
import SwiftData

/// What a journal line records. Declared here, outside the `#if`, because
/// every triage verb in `AppState` names one of these when it calls
/// `journal(...)` — the call sites are the same in both builds, so the
/// vocabulary has to be too. `JournalWriter` (direct build only) renders it.
enum JournalAction: String, Sendable {
    case arrived
    case done
    /// Finished for real in its source, by `C` on a to-do row. Distinct from
    /// `done` on purpose: reading back a week of triage, "I dismissed this"
    /// and "I did this" are not the same admission.
    case completed
    case snoozed
    case pinned
    case unpinned
    case restored
}

#if !APP_STORE

/// `AppState`'s side of the journal: the preferences, and the fire-and-forget
/// recording every triage verb calls into.
///
/// Lives in `Journal/` rather than in `AppState.swift` so the rest of the
/// folder can be left out of the App Store build, where a sandboxed app cannot
/// write to a user-typed vault path (see `docs/app-store-plan.md`). This one
/// file is compiled into **both** targets: the `#else` branch below is the
/// store build's no-op version of every method `AppState` calls, so those call
/// sites compile unchanged. `AppState` keeps only the stored `journalError`,
/// which an extension cannot hold.
///
/// Preferences use the manual `access`/`withMutation` pair because they are
/// computed over `UserDefaults`, exactly as they did inside the class body.
extension AppState {
    /// Off by default, and with no default path: the useful value is a
    /// personal vault location that only the user can supply.
    var journalEnabled: Bool {
        get {
            access(keyPath: \.journalEnabled)
            return UserDefaults.standard.bool(forKey: "journalEnabled")
        }
        set {
            withMutation(keyPath: \.journalEnabled) {
                UserDefaults.standard.set(newValue, forKey: "journalEnabled")
            }
        }
    }

    var journalPath: String {
        get {
            access(keyPath: \.journalPath)
            return UserDefaults.standard.string(forKey: "journalPath") ?? ""
        }
        set {
            withMutation(keyPath: \.journalPath) {
                UserDefaults.standard.set(newValue, forKey: "journalPath")
            }
        }
    }

    var journalHeading: String {
        get {
            access(keyPath: \.journalHeading)
            let stored = UserDefaults.standard.string(forKey: "journalHeading")
            return (stored?.isEmpty == false) ? stored! : "## Inbox & Chill"
        }
        set {
            withMutation(keyPath: \.journalHeading) {
                UserDefaults.standard.set(newValue, forKey: "journalHeading")
            }
        }
    }

    /// The two halves of Brandon's ask: log what arrives, and log what you
    /// did about it. Either can be turned off independently.
    var journalLogArrivals: Bool {
        get {
            access(keyPath: \.journalLogArrivals)
            return UserDefaults.standard.object(forKey: "journalLogArrivals")
                as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.journalLogArrivals) {
                UserDefaults.standard.set(newValue, forKey: "journalLogArrivals")
            }
        }
    }

    var journalLogActions: Bool {
        get {
            access(keyPath: \.journalLogActions)
            return UserDefaults.standard.object(forKey: "journalLogActions")
                as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.journalLogActions) {
                UserDefaults.standard.set(newValue, forKey: "journalLogActions")
            }
        }
    }

    private var journalConfig: JournalConfig {
        JournalConfig(pathTemplate: journalPath, heading: journalHeading)
    }

    /// Fire-and-forget, but never silent: failures land in `journalError`.
    func journal(_ entries: [JournalEntry]) {
        guard journalEnabled, !entries.isEmpty else { return }
        let config = journalConfig
        Task {
            for entry in entries {
                do {
                    try await JournalWriter.shared.record(entry, config: config)
                } catch {
                    await MainActor.run {
                        self.journalError = String(describing: error)
                    }
                    ProblemLog.note(
                        .journal,
                        "Couldn't write the journal: \(error.localizedDescription)",
                        detail: String(describing: error))
                    return
                }
            }
            await MainActor.run { self.journalError = nil }
        }
    }

    /// The arrivals half, called from `AppState.handle` for every reconcile.
    /// Owns its own `journalLogArrivals` guard so the call site is one line
    /// in both builds.
    func journalArrivals(_ change: QueueChange) {
        guard journalEnabled, journalLogArrivals, !change.inserted.isEmpty else { return }
        let name = sourceName(forID: change.sourceID)
        journal(
            change.inserted.map {
                JournalEntry(
                    at: .now, action: .arrived, sourceName: name,
                    title: $0.title, url: $0.urlString, detail: nil)
            })
    }

    func journal(
        _ action: JournalAction, item: Item, detail: String? = nil
    ) {
        guard journalEnabled, journalLogActions else { return }
        journal([
            JournalEntry(
                at: .now, action: action,
                sourceName: sourceName(forID: item.sourceID),
                title: item.title, url: item.url?.absoluteString, detail: detail)
        ])
    }

    /// The batch form, carrying the same `journalLogActions` guard.
    ///
    /// One line per item, not one per gesture: the journal is a record of
    /// notifications, and folding four of them into "dismissed a topic" would
    /// lose the four things that were actually dealt with.
    func journal(
        _ action: JournalAction, items: [Item],
        detail: (Item) -> String? = { _ in nil }
    ) {
        guard journalEnabled, journalLogActions else { return }
        journal(
            items.map { item in
                JournalEntry(
                    at: .now, action: action,
                    sourceName: sourceName(forID: item.sourceID),
                    title: item.title, url: item.url?.absoluteString,
                    detail: detail(item))
            })
    }

    /// "waited 4m" for a lone row, "waited 4m · EPD-1873" inside a topic.
    static func waited(
        _ item: Item, topicName: String?
    ) -> String? {
        let waited = JournalWriter.waited(from: item.firstSeenAt, to: .now)
        guard let topicName else { return waited }
        guard let waited else { return topicName }
        return "\(waited) · \(topicName)"
    }

    /// Snooze targets are read by humans in a note, so this one is localised
    /// (unlike the journal's machine-stable `HH:mm` timestamp).
    static let journalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

#else

/// The App Store build has no journal: a sandboxed app cannot write to a
/// vault path the user typed, and an iCloud Obsidian vault needs Full Disk
/// Access, which a sandboxed app cannot be granted. Every method `AppState`
/// calls is here with the same signature and does nothing, so the triage
/// verbs compile unchanged. `journalEnabled` stays `false` so any remaining
/// `if journalEnabled` read in shared code is honest about it.
extension AppState {
    var journalEnabled: Bool { false }
    var journalLogActions: Bool { false }

    func journalArrivals(_ change: QueueChange) {}

    func journal(_ action: JournalAction, item: Item, detail: String? = nil) {}

    func journal(
        _ action: JournalAction, items: [Item],
        detail: (Item) -> String? = { _ in nil }
    ) {}

    static func waited(_ item: Item, topicName: String?) -> String? { nil }

    static let journalDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

#endif
