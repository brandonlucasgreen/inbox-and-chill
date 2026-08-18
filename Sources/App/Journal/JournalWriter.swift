import Foundation

/// What happened to an item, as recorded in the journal.
enum JournalAction: String, Sendable {
    case arrived
    case done
    case snoozed
    case pinned
    case unpinned
    case restored
}

/// One line's worth of journal. Built on the MainActor from a live `Item`,
/// then handed to the writer actor.
struct JournalEntry: Sendable {
    var at: Date
    var action: JournalAction
    var sourceName: String
    var title: String
    var url: String?
    /// Trailing context: how long a done item waited, when a snooze lands.
    var detail: String?
}

/// Where and how to write. Read from prefs at the moment of each write, so
/// changing the path in Settings takes effect on the next entry.
struct JournalConfig: Sendable {
    var pathTemplate: String
    var heading: String
}

/// Appends triage activity to a Markdown file — built for an Obsidian daily
/// note, but it's a plain file, so anything that reads text can consume it.
///
/// The point is reflection after the fact: an agent (or you) reading back
/// what arrived, what you did about it, and how long it sat there.
///
/// Everything interesting here is a pure function — path templating, line
/// rendering, and section insertion are `static` and side-effect free, so
/// they're unit-tested directly. The actor exists only to serialise the file
/// IO so two rapid entries can't interleave a read-modify-write.
actor JournalWriter {
    static let shared = JournalWriter()

    struct JournalError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        var description: String { errorDescription ?? "Journal error" }
    }

    /// Machine-stable, locale-independent. A journal that renders as `09:41`
    /// for one user and `9:41 AM` for another is a journal nothing can parse.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let pathFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Path templating

    /// Expands `{{YYYY}}`, `{{MM}}`, `{{DD}}` and a leading `~` in a path
    /// template. Returns `nil` for a blank template — that's "not configured",
    /// not an error.
    ///
    /// The token spelling deliberately mirrors Obsidian's daily-note format
    /// so the string a user already has in Obsidian's settings works here.
    nonisolated static func resolvePath(
        template: String, date: Date, calendar: Calendar = .current
    ) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day
        else { return nil }

        var path = trimmed
        for (token, value) in [
            ("{{YYYY}}", String(format: "%04d", year)),
            ("{{MM}}", String(format: "%02d", month)),
            ("{{DD}}", String(format: "%02d", day)),
        ] {
            path = path.replacingOccurrences(of: token, with: value)
        }

        // Tilde only expands at the front; a `~` mid-path is a literal
        // directory name and must survive.
        if path == "~" || path.hasPrefix("~/") {
            path = (path as NSString).expandingTildeInPath
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Line rendering

    /// `- 09:41 · **done** · Linear · [Fix the flaky test](https://…) · waited 11m`
    ///
    /// Fixed field order with a `·` separator: readable in Obsidian, and
    /// regular enough that an agent can split it back apart.
    nonisolated static func line(for entry: JournalEntry) -> String {
        var fields = [
            timeFormatter.string(from: entry.at),
            "**\(entry.action.rawValue)**",
            sanitize(entry.sourceName.isEmpty ? "unknown" : entry.sourceName),
        ]

        let title = sanitize(entry.title)
        // An empty link target renders as broken markdown, so only link when
        // there's somewhere to go.
        if let url = entry.url?.trimmingCharacters(in: .whitespacesAndNewlines),
            !url.isEmpty
        {
            fields.append("[\(title)](\(url))")
        } else {
            fields.append(title)
        }

        if let detail = entry.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
            !detail.isEmpty
        {
            fields.append(sanitize(detail))
        }
        return "- " + fields.joined(separator: " · ")
    }

    /// Flattens anything that would break a one-bullet-per-event file or the
    /// markdown link around it. A Slack message pasted with newlines must not
    /// become five journal lines.
    nonisolated static func sanitize(_ text: String) -> String {
        let flattened = text.components(
            separatedBy: .whitespacesAndNewlines
        ).filter { !$0.isEmpty }.joined(separator: " ")
        return
            flattened
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }

    /// "waited 11m" / "waited 3h 12m" / "waited 2d 4h" — the bit that makes
    /// this useful for reflection rather than just an audit log.
    nonisolated static func waited(from firstSeen: Date, to doneAt: Date) -> String? {
        let seconds = Int(doneAt.timeIntervalSince(firstSeen))
        guard seconds >= 60 else { return nil }  // sub-minute is noise
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "waited \(days)d \(hours % 24)h" }
        if hours > 0 { return "waited \(hours)h \(minutes % 60)m" }
        return "waited \(minutes)m"
    }

    // MARK: - Section insertion

    /// Places `line` at the end of `heading`'s section, creating the section
    /// at the end of the document if it isn't there.
    ///
    /// Care is needed because the target is usually a daily note that already
    /// has a template's worth of headings in it: we must land inside our own
    /// section (never bleed into the next one), after any entries already
    /// there (so the file reads chronologically), and above the blank lines
    /// that separate the section from what follows.
    nonisolated static func insert(
        line: String, into content: String, heading: String
    ) -> String {
        let normalizedHeading = heading.trimmingCharacters(in: .whitespaces)
        guard !normalizedHeading.isEmpty else {
            return appendingSection(line: line, to: content, heading: "## Journal")
        }

        var lines = content.components(separatedBy: "\n")
        guard
            let headingIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == normalizedHeading
            })
        else {
            return appendingSection(
                line: line, to: content, heading: normalizedHeading)
        }

        // Our section runs until the next ATX heading of any level.
        let sectionStart = headingIndex + 1
        var sectionEnd = lines.count
        if sectionStart < lines.count {
            for index in sectionStart..<lines.count
            where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                sectionEnd = index
                break
            }
        }

        // Insert after the section's last non-blank line, so trailing blank
        // separators stay between us and the next heading.
        var insertAt = sectionStart
        if sectionStart < sectionEnd {
            for index in stride(from: sectionEnd - 1, through: sectionStart, by: -1)
            where !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt = index + 1
                break
            }
        }
        lines.insert(line, at: insertAt)
        return lines.joined(separator: "\n")
    }

    private nonisolated static func appendingSection(
        line: String, to content: String, heading: String
    ) -> String {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(heading)\n\n\(line)\n"
        }
        // Exactly one blank line between existing content and our heading,
        // however much trailing whitespace the file happened to have.
        let trimmed = String(
            content.reversed().drop { $0 == "\n" }.reversed())
        return "\(trimmed)\n\n\(heading)\n\n\(line)\n"
    }

    // MARK: - Writing

    /// Appends one entry. Throws so the caller can surface the reason —
    /// a journal that silently stops writing is worse than no journal.
    func record(_ entry: JournalEntry, config: JournalConfig) throws {
        guard
            let url = Self.resolvePath(
                template: config.pathTemplate, date: entry.at)
        else {
            throw JournalError(
                errorDescription:
                    "Journal path “\(config.pathTemplate)” isn't a usable absolute path.")
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = Self.insert(
                line: Self.line(for: entry), into: existing, heading: config.heading)
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw Self.explain(error, url: url)
        }
    }

    /// Turns a bare "Operation not permitted" into something a person can act
    /// on. The usual cause is a path macOS protects, and the most likely one
    /// here is an Obsidian vault kept in iCloud: `iCloud~md~obsidian` is
    /// *Obsidian's* container, and reaching into another app's container needs
    /// Full Disk Access — no prompt appears, the write just fails.
    nonisolated static func explain(_ error: Error, url: URL) -> Error {
        let nsError = error as NSError
        let isPermission =
            (nsError.domain == NSCocoaErrorDomain
                && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError]
                    .contains(nsError.code))
            || (nsError.domain == NSPOSIXErrorDomain
                && [Int(EPERM), Int(EACCES)].contains(nsError.code))
        guard isPermission else { return error }

        if url.path.contains("/Library/Mobile Documents/") {
            return JournalError(
                errorDescription: """
                    macOS blocked writing to \(url.path) — it's inside another app's \
                    iCloud container. Either grant Inbox & Chill Full Disk Access \
                    (System Settings → Privacy & Security → Full Disk Access), or \
                    choose a journal path outside iCloud.
                    """)
        }
        return JournalError(
            errorDescription: """
                macOS blocked writing to \(url.path). Allow Inbox & Chill under \
                System Settings → Privacy & Security → Files and Folders, or choose \
                another path.
                """)
    }
}
