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

    /// "Last refreshed just now" / "Last refreshed 4m ago".
    ///
    /// `relative` is built for row timestamps, where a bare "now" reads fine
    /// next to a title. Slotted into a sentence it produced "Last refreshed
    /// now ago", so the phrase is composed here rather than at each call site
    /// — a clock skew that puts the refresh slightly in the future ("soon
    /// ago") has the same problem and is handled by the same branch.
    static func refreshed(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "Last refreshed just now" }
        return "Last refreshed \(relative(date, now: now)) ago"
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
///
/// 7pt of colour is the entire message, so the hint is the only thing that
/// explains it — and a system tooltip never renders in the menu bar panel
/// (`PanelHint`). The hit target is padded well past the dot itself, because
/// a 7×7 hover target is a target nobody hits by accident.
struct SourceStatusDot: View {
    let display: SourceDisplay
    let status: ConnectorStatus?
    @Binding var hoveredHint: PanelHint?

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 7, height: 7)
            .frame(width: 13, height: 24)
            .contentShape(.rect)
            .panelHint(
                SourceStatusDot.describe(name: display.name, status: status),
                highlight: false, hovered: $hoveredHint)
    }

    private var tint: Color {
        switch status {
        case .ok?: return .green
        case .error?: return .red
        default: return .secondary
        }
    }

    /// What this dot's colour means, in words.
    ///
    /// Pure and static so the tests can cover every status case: this string
    /// is the only place the app ever says why a dot is red.
    nonisolated static func describe(
        name: String, status: ConnectorStatus?, now: Date = .now
    ) -> String {
        switch status {
        case .ok(let date)?:
            return "\(name) — synced \(PanelFormat.relative(date, now: now)) ago"
        case .error(let message)?:
            return "\(name) — error: \(clamped(message))"
        case .connecting?: return "\(name) — connecting…"
        case nil: return "\(name) — not synced yet"
        }
    }

    /// Connector errors are usually a short API code, but not always — and
    /// the hint bubble is one line inside a 420pt panel. Settings shows the
    /// full message; this only has to say which dot went red and roughly why.
    private nonisolated static func clamped(_ message: String) -> String {
        let limit = 48
        guard message.count > limit else { return message }
        let head = message.prefix(limit).trimmingCharacters(in: .whitespaces)
        return "\(head)…"
    }
}

/// How much background a queue row paints for hover and keyboard selection.
///
/// Selection used to be `NSColor.selectedContentBackgroundColor` — a
/// saturated blue slab in a panel that is otherwise all greys, loud enough to
/// read as an alert rather than as a cursor. It is now a neutral tonal step:
/// the same fill hover uses, plus more `Color.primary` on top of it, plus a
/// hairline edge that hover never draws.
///
/// Two properties the numbers exist to hold:
///
/// - Selection layers *over* the hover fill instead of replacing it, so a
///   selected row is denser than a hovered one by construction — whatever
///   `.quaternary` happens to resolve to in the current appearance and
///   material. Both states can apply to the same row, and ↑/↓ selection has
///   to stay unambiguous when they do.
/// - The weights ride on `Color.primary`, which is black in light mode and
///   white in dark, so one set of numbers darkens a light panel and lightens
///   a dark one. A fixed grey would only be right in one of them, and the
///   panel sits on `.bar` material where there is no fixed backdrop to
///   match anyway.
struct RowFocus: Equatable {
    /// `Color.primary` opacity layered above the shared hover fill.
    var fill: Double
    /// `Color.primary` opacity for the 1pt border; 0 draws none. Carried by
    /// selection only, so the border alone tells the two states apart.
    var border: Double
    /// Whether the shared `.quaternary` fill is painted at all.
    var hasBaseFill: Bool

    static let unfocused = RowFocus(fill: 0, border: 0, hasBaseFill: false)
    static let hovered = RowFocus(fill: 0, border: 0, hasBaseFill: true)
    /// Panel owns key: selection has to stay findable while scanning with
    /// ↑/↓, so this is the loudest step — quiet, but never in doubt.
    static let selected = RowFocus(fill: 0.08, border: 0.15, hasBaseFill: true)
    /// Panel lost key (snooze popover, Settings window). Dimmed to match the
    /// rest of the chrome, still clearly a selection.
    static let selectedInactive =
        RowFocus(fill: 0.02, border: 0.08, hasBaseFill: true)

    static func resolve(
        isSelected: Bool, isHovering: Bool, isKey: Bool
    ) -> RowFocus {
        guard isSelected else { return isHovering ? .hovered : .unfocused }
        return isKey ? .selected : .selectedInactive
    }
}

/// The queue's motion, in one place.
///
/// Rows leaving the list and the scroll that follows them used to run on
/// different curves *at the same time* — a 0.22s snappy collapse against a
/// 0.15s easeInOut scroll — and two curves driving the same pixels is what
/// reads as jagged. Everything that moves the queue now shares one animation,
/// so a dismissal is a single coordinated gesture.
enum PanelMotion {
    static let duration: TimeInterval = 0.22

    /// `nil` when the user has asked the system for less motion, so callers can
    /// pass this straight to `withAnimation` and `.animation(_:value:)`.
    static func queue(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: duration)
    }

    /// Rows fade rather than slide.
    ///
    /// Removal used to combine opacity with `.move(edge: .leading)`, so a
    /// dismissed row travelled sideways while every row beneath it jumped
    /// upward to close the gap — two directions at once, in a `LazyVStack`
    /// that realises rows on demand. Letting the height collapse carry the
    /// motion on its own is both smoother and honest about what happened.
    /// Computed rather than stored: `AnyTransition` isn't `Sendable`, so a
    /// static constant would be shared mutable state under strict concurrency.
    static var row: AnyTransition { .opacity }
}
