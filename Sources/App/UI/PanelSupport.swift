import AppKit
import SwiftUI

/// Presentation metadata for one source: name + glyph, resolved from the
/// stored `SourceConfig` when there is one and from `ConnectorCatalog`
/// otherwise (DEBUG fake connector, sources removed mid-session).
struct SourceDisplay: Identifiable, Hashable, Sendable {
    var id: String  // sourceID
    var kind: String
    var name: String
    var systemImage: String
    var sortOrder: Int

    static func fallback(kind: String, sourceID: String) -> SourceDisplay {
        let descriptor = ConnectorCatalog.descriptor(for: kind)
        return SourceDisplay(
            id: sourceID, kind: kind,
            name: descriptor?.displayName
                ?? (kind.isEmpty ? "Other" : kind.capitalized),
            systemImage: descriptor?.systemImage ?? "tray",
            sortOrder: Int.max / 2)
    }
}

/// sourceID → `SourceDisplay`, built fresh from the current queries. Cheap:
/// the panel only ever holds a handful of sources.
struct SourceIndex {
    private var byID: [String: SourceDisplay] = [:]

    init(configs: [SourceConfig], items: [Item]) {
        for config in configs {
            let descriptor = ConnectorCatalog.descriptor(for: config.kind)
            byID[config.id] = SourceDisplay(
                id: config.id, kind: config.kind,
                name: config.displayName.isEmpty
                    ? (descriptor?.displayName ?? config.kind.capitalized)
                    : config.displayName,
                systemImage: descriptor?.systemImage ?? "tray",
                sortOrder: config.sortOrder)
        }
        for item in items where byID[item.sourceID] == nil {
            byID[item.sourceID] = .fallback(
                kind: item.sourceKind, sourceID: item.sourceID)
        }
    }

    func display(_ sourceID: String, kind: String = "") -> SourceDisplay {
        byID[sourceID] ?? .fallback(kind: kind, sourceID: sourceID)
    }

    func display(for item: Item) -> SourceDisplay {
        display(item.sourceID, kind: item.sourceKind)
    }

    /// Config order first, then alphabetical for anything unconfigured.
    func ordered(ids: some Sequence<String>) -> [SourceDisplay] {
        Set(ids).map { display($0) }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }
}

/// One rendered source section of the active queue.
struct SourceGroup: Identifiable {
    var id: String { source.id }
    let source: SourceDisplay
    let items: [Item]
}

/// Compact, panel-sized date formatting ("2h", "3d") plus full strings for
/// tooltips.
enum PanelFormat {
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return "soon" }
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        case ..<(52 * 7 * 86_400): return "\(Int(seconds / (7 * 86_400)))w"
        default: return "\(Int(seconds / (365 * 86_400)))y"
        }
    }

    static func full(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "Snoozed until 6:00 PM" style, day-aware.
    static func until(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// ⌘C / context-menu copy: writes every flavor a paste target might ask
/// for in one deterministic pass — `.URL` so Safari's address bar and
/// Finder get a real link, `.html`/`.rtf` so rich documents (Notes,
/// TextEdit, Slack) get a styled link, and `.string` so plain-text fields
/// (terminals, chat composers) get something legible either way.
enum PanelPasteboard {
    static func copy(title: String, url: URL?) {
        let board = NSPasteboard.general
        board.clearContents()

        guard let url else {
            let item = NSPasteboardItem()
            item.setString(title, forType: .string)
            board.writeObjects([item])
            return
        }

        let plain = "\(title) — \(url.absoluteString)"
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(
            "<a href=\"\(escaped(url.absoluteString))\">\(escaped(title))</a>",
            forType: .html)
        if let rtf = rtfLink(title: title, url: url) {
            item.setData(rtf, forType: .rtf)
        }
        item.setString(plain, forType: .string)
        // Single write: one item carrying every flavor, so every paste
        // target — Safari's URL-only address bar, a rich-text document, a
        // plain-text field — reads back a consistent, correct value.
        board.writeObjects([item])
    }

    private static func rtfLink(title: String, url: URL) -> Data? {
        let attributed = NSAttributedString(
            string: title,
            attributes: [.link: url])
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private static func escaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Footer sync indicator for one source.
struct SourceStatusDot: View {
    let display: SourceDisplay
    let status: ConnectorStatus?

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .help(tooltip)
            .accessibilityLabel(Text(tooltip))
    }

    private var tint: Color {
        switch status {
        case .ok?: return .green
        case .error?: return .red
        default: return .secondary
        }
    }

    private var tooltip: String {
        switch status {
        case .ok(let date)?:
            return "\(display.name) — synced \(PanelFormat.relative(date)) ago"
        case .error(let message)?:
            return "\(display.name) — error: \(message)"
        case .connecting?: return "\(display.name) — connecting…"
        case nil: return "\(display.name) — not synced yet"
        }
    }
}
