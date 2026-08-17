import AppKit
import SwiftUI

/// Sidebar scope for the main triage window: the four fixed lists plus one
/// row per source. Persisted per-scene through `@SceneStorage` (§5.3) so a
/// reopened window lands where you left it.
enum TriageScope: Hashable, Sendable {
    case all
    case pinned
    case snoozed
    /// Done items from the last 90 days (§2.1.6).
    case archive
    case source(String)  // sourceID

    static let fixed: [TriageScope] = [.all, .pinned, .snoozed, .archive]

    // MARK: Persistence

    var storageValue: String {
        switch self {
        case .all: return "all"
        case .pinned: return "pinned"
        case .snoozed: return "snoozed"
        case .archive: return "archive"
        case .source(let id): return "source:\(id)"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "pinned": self = .pinned
        case "snoozed": self = .snoozed
        case "archive": self = .archive
        default:
            let prefix = "source:"
            if storageValue.hasPrefix(prefix) {
                self = .source(String(storageValue.dropFirst(prefix.count)))
            } else {
                self = .all
            }
        }
    }

    // MARK: Presentation

    private var fixedTitle: String? {
        switch self {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .snoozed: return "Snoozed"
        case .archive: return "Archive"
        case .source: return nil
        }
    }

    private var fixedSystemImage: String? {
        switch self {
        case .all: return "tray.full"
        case .pinned: return "pin"
        case .snoozed: return "clock"
        case .archive: return "archivebox"
        case .source: return nil
        }
    }

    func title(in index: SourceIndex) -> String {
        if let fixedTitle { return fixedTitle }
        guard case .source(let id) = self else { return "All" }
        return index.display(id).name
    }

    func systemImage(in index: SourceIndex) -> String {
        if let fixedSystemImage { return fixedSystemImage }
        guard case .source(let id) = self else { return "tray.full" }
        return index.display(id).systemImage
    }

    var help: String {
        switch self {
        case .all: return "Everything still in the queue"
        case .pinned: return "Pinned items — immortal until unpinned"
        case .snoozed: return "Snoozed items, with their wake times"
        case .archive: return "Done items from the last 90 days"
        case .source: return "Queued items from this source"
        }
    }

    // MARK: Membership

    /// Whether an item belongs to this scope, before search narrowing.
    func contains(_ item: Item, now: Date = .now) -> Bool {
        switch self {
        case .all:
            return !item.isDone
        case .pinned:
            return item.isPinned && !item.isDone
        case .snoozed:
            return item.isSnoozed
        case .archive:
            guard let doneAt = item.doneAt else { return false }
            return doneAt >= TriagePolicy.purgeCutoff(now: now)
        case .source(let id):
            return !item.isDone && item.sourceID == id
        }
    }

    // MARK: Zero states

    func emptyTitle(in index: SourceIndex) -> String {
        switch self {
        case .all: return "You're all caught up ☺"
        case .pinned: return "Nothing pinned"
        case .snoozed: return "Nothing snoozed"
        case .archive: return "Nothing archived"
        case .source: return "Nothing from \(title(in: index))"
        }
    }

    var emptyDetail: String? {
        switch self {
        case .all:
            return nil  // The window shows the last sync time instead.
        case .pinned:
            return
                "⌘P pins an item: pinned items are exempt from auto-clear and "
                + "the 90-day purge."
        case .snoozed:
            return "Snoozed items always come back with a banner."
        case .archive:
            return
                "Done items stay here for 90 days before they're purged. ⌘Z "
                + "puts one back."
        case .source:
            return "Nothing from this source is waiting on you."
        }
    }

    var emptySystemImage: String {
        switch self {
        case .all: return "cup.and.saucer"
        case .pinned: return "pin.slash"
        case .snoozed: return "clock"
        case .archive: return "archivebox"
        case .source: return "tray"
        }
    }
}

/// One scope as the View menu sees it: a title, a glyph, and the ⌘-number it
/// answers to (⌘1…⌘4 for the fixed scopes, ⌘5…⌘9 for the first sources).
struct ScopeShortcut: Identifiable, Hashable, Sendable {
    var scope: TriageScope
    var title: String
    var systemImage: String
    var shortcutNumber: Int?

    var id: TriageScope { scope }
}

extension Item {
    /// Sort/display keys for the main window's table. The table sorts in
    /// memory, so computed properties are fair game here — a
    /// `FetchDescriptor` would need stored ones.
    var kindLabel: String {
        kind.split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    var actorSortKey: String { actorName ?? "" }

    /// Pinned first when sorted ascending.
    var pinSortKey: Int { isPinned ? 0 : 1 }
}

/// ⌘C over a multi-row selection: newline-joined "title — url" as plain
/// text, plus an HTML list so a paste into Notes or Slack keeps the links.
/// A single row defers to `PanelPasteboard` so the panel and the window put
/// exactly the same thing on the pasteboard.
enum MainWindowPasteboard {
    static func copy(_ items: [Item]) {
        guard let first = items.first else { return }
        guard items.count > 1 else {
            PanelPasteboard.copy(title: first.title, url: first.url)
            return
        }
        let plain =
            items
            .map { item in
                item.url.map { "\(item.title) — \($0.absoluteString)" }
                    ?? item.title
            }
            .joined(separator: "\n")
        let html =
            items
            .map { item -> String in
                guard let url = item.url else {
                    return "<div>\(escaped(item.title))</div>"
                }
                return "<div><a href=\"\(escaped(url.absoluteString))\">"
                    + "\(escaped(item.title))</a></div>"
            }
            .joined()

        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.html, .string], owner: nil)
        board.setString(html, forType: .html)
        board.setString(plain, forType: .string)
    }

    private static func escaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
