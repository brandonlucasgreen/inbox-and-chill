import Foundation
import OSLog

/// Reads Mail.app over AppleScript. Covers every account Mail has, which is
/// why there is no Gmail connector — see PLAN §6.13.
///
/// **Three facts shaped this connector** (all measured on real Mail,
/// 2026-08-19):
///
/// 1. `unread count of inbox` costs 0.12s, but
///    `messages of inbox whose read status is false` costs **12s cold and
///    0.15s warm** — the 12s is Mail waking up on its first Apple Event
///    after idling. So a slow first poll is normal and must never be
///    reported as a broken source.
/// 2. Reading `~/Library/Mail` directly (the Envelope Index) is not an
///    option: it is TCC-protected, so it needs Full Disk Access on top of a
///    private schema. AppleScript is the honest path (PLAN §6.12, and the
///    same rejection as the Notification Center DB in §6.8).
/// 3. Mail's AppleScript needs explicit coercion — `subject of m as text`,
///    not `subject of m` — and dates must be decomposed into components,
///    because `date received as string` is locale-dependent and unparseable.
///
/// Default scope is **flagged only**. "Unread in INBOX" is thousands of
/// messages for most people and would bury every other source in the queue.
actor AppleMailConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "appleMail"
    nonisolated let capabilities: ConnectorCapabilities = [.markDone, .remoteTruth]
    nonisolated let pollInterval: TimeInterval = 60

    private let scope: Scope
    private var snapshotComplete = true

    private static let log = AppLog.logger(.appleMail)

    /// Which messages count as queue-worthy. Both can be on; a message that
    /// is flagged *and* unread is reported once, as flagged, because
    /// unflagging is the more deliberate gesture.
    struct Scope: Sendable, Equatable {
        var flagged: Bool
        var unread: Bool
        /// Empty means Mail's unified inbox.
        var mailbox: String

        var isEmpty: Bool { !flagged && !unread }
    }

    /// Past this many messages the snapshot is reported incomplete rather
    /// than letting `.remoteTruth` archive the tail — the trap
    /// `GitHubConnector` documents. It is also a mercy to Mail: the
    /// enumeration cost is per message.
    ///
    /// Slicing `items 1 thru maxMessages` keeps the *newest* messages:
    /// verified 2026-08-19 that Mail returns `messages of inbox`
    /// newest-first (item 1 was two months later than item n). If that ever
    /// changes, the cap silently starts triaging the oldest mail in the
    /// box — so it is worth re-checking rather than assuming.
    static let maxMessages = 100

    /// Shown instead of a subject when Mail refuses to describe a message.
    /// Kept as a constant because both the AppleScript and the tests need
    /// the exact same string.
    static let undescribedTitle = "(Mail wouldn’t describe this message)"

    init(sourceID: String, scope: Scope) {
        self.sourceID = sourceID
        self.scope = scope
    }

    struct AppleMailError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        var description: String { errorDescription ?? "Apple Mail connector error" }
    }

    // MARK: Fetch

    func fetch() async throws -> [RemoteItem] {
        guard !scope.isEmpty else {
            throw AppleMailError(
                errorDescription:
                    "Apple Mail: nothing is selected to watch. Turn on “Flagged messages” or “Unread messages” for this source."
            )
        }

        // Ask macOS before sending the event, never after.
        //
        // The non-prompting check is silent and cheap, and it buys two
        // things. It turns every permission state into a named reason on the
        // *first* poll rather than a -1743 the user only sees if they go
        // looking. And it stops a background timer from being what raises
        // macOS's Automation dialog: `tell application "Mail"` launches Mail
        // and can trigger the prompt, so a poll that runs before the user has
        // ever been asked spends the one prompt macOS gives, unattributed, up
        // to 60s after they last touched the app. `MailAutomation.resolve`
        // with `prompting: false` cannot show a dialog; only the button in
        // Settings passes `true`.
        let permission = await MailAutomation.resolve(prompting: false)
        if let refusal = permission.fetchRefusal {
            throw AppleMailError(errorDescription: refusal)
        }

        let output = try await Self.runScript(Self.fetchScript(scope: scope))
        let (items, truncated) = Self.items(fromScriptOutput: output)
        snapshotComplete = !truncated
        if truncated {
            Self.log.info(
                "Mail snapshot truncated at \(Self.maxMessages, privacy: .public) messages; not archiving the tail"
            )
        }
        return items
    }

    func snapshotWasComplete() async -> Bool { snapshotComplete }

    // MARK: Write-through

    /// Marking done means the opposite gesture to whichever one queued it:
    /// unflag a flagged message, mark an unread one read. Doing both would
    /// silently discard state the user set in Mail on purpose.
    func markDone(externalID: String, payload: Data?) async throws {
        guard let handle = MessageHandle(payload: payload) else {
            throw AppleMailError(
                errorDescription:
                    "Apple Mail: “\(externalID)” has no Mail message id recorded, so it can't be changed in Mail. It was cleared from the queue only."
            )
        }
        _ = try await Self.runScript(Self.markDoneScript(handle: handle))
    }

    // MARK: Addressing a message

    /// How to find a message again. The numeric id is Mail's own and is what
    /// AppleScript can address directly; the RFC Message-ID is the stable
    /// half and is what `message://` links use. Keeping both is why an item
    /// survives a Mail reindex *and* stays clickable.
    struct MessageHandle: Sendable, Equatable, Codable {
        var mailID: Int
        var messageID: String?
        var unflag: Bool
        /// Mail's `id` is scoped to a mailbox, not global, so a bare id
        /// looked up in the unified inbox is not reliably the message we
        /// meant. These two make it exact. Optional because handles written
        /// by 0.3.0 don't have them.
        var account: String?
        var mailbox: String?

        init(
            mailID: Int, messageID: String?, unflag: Bool,
            account: String? = nil, mailbox: String? = nil
        ) {
            self.mailID = mailID
            self.messageID = messageID
            self.unflag = unflag
            self.account = account
            self.mailbox = mailbox
        }

        init?(payload: Data?) {
            guard let payload,
                let decoded = try? JSONDecoder().decode(Self.self, from: payload)
            else { return nil }
            self = decoded
        }

        var encoded: Data? { try? JSONEncoder().encode(self) }
    }

    // MARK: Pure helpers (rule 5)

    /// Field and record separators are ASCII 31/30 — control characters that
    /// cannot occur in a subject line, which a tab or a pipe absolutely can.
    static let fieldSeparator = "\u{1F}"
    static let recordSeparator = "\u{1E}"

    static func fetchScript(scope: Scope) -> String {
        let container =
            scope.mailbox.isEmpty
            ? "inbox" : "mailbox \(quoted(scope.mailbox))"
        var clauses: [String] = []
        // Flagged first: a message that is both is reported as flagged, and
        // the `not flagged` on the unread clause is what keeps it single.
        if scope.flagged {
            clauses.append(
                "set candidates to candidates & (messages of \(container) whose flagged status is true)"
            )
        }
        if scope.unread {
            // When flagged messages are also being collected, exclude them
            // here — otherwise a flagged-and-unread message arrives twice
            // with two different `kind`s and two different done gestures.
            let clause =
                scope.flagged
                ? "read status is false and flagged status is false"
                : "read status is false"
            clauses.append(
                "set candidates to candidates & (messages of \(container) whose \(clause))")
        }

        return """
            set fieldSep to (character id 31)
            set recSep to (character id 30)
            set out to ""
            set truncated to "0"
            tell application "Mail"
                set candidates to {}
                \(clauses.joined(separator: "\n    "))
                set total to count of candidates
                if total > \(maxMessages) then
                    set truncated to "1"
                    set candidates to items 1 thru \(maxMessages) of candidates
                end if
                repeat with m in candidates
                    set rec to ""
                    try
                        set d to date received of m
                        set theID to ""
                        try
                            set theID to (message id of m) as text
                        end try
                        set rec to ((id of m) as text) & fieldSep & theID ¬
                            & fieldSep & (subject of m as text) ¬
                            & fieldSep & (sender of m as text) ¬
                            & fieldSep & ((year of d) as text) & "-" & (my pad(month of d as integer)) & "-" & (my pad(day of d)) ¬
                            & " " & (my pad(hours of d)) & ":" & (my pad(minutes of d)) & ":" & (my pad(seconds of d)) ¬
                            & fieldSep & ((flagged status of m) as text) ¬
                            & fieldSep & ((read status of m) as text) ¬
                            & fieldSep & ((id of (account of (mailbox of m))) as text) ¬
                            & fieldSep & ((name of (mailbox of m)) as text)
                    on error
                        -- Rule 4: a message Mail won't describe still gets a
                        -- row. Dropping it silently is the one outcome this
                        -- must not have — the queue would be quietly short
                        -- and nothing would say so.
                        try
                            set rec to ((id of m) as text) & fieldSep & "" ¬
                                & fieldSep & "\(undescribedTitle)" ¬
                                & fieldSep & "" & fieldSep & "" ¬
                                & fieldSep & "false" & fieldSep & "false" ¬
                                & fieldSep & "" & fieldSep & ""
                        end try
                    end try
                    if rec is not "" then set out to out & rec & recSep
                end repeat
            end tell
            return truncated & recSep & out

            on pad(n)
                set s to n as text
                if (count of characters of s) < 2 then return "0" & s
                return s
            end pad
            """
    }

    /// Marking done means "I dealt with this email": mark it **read**, and
    /// unflag it too if a flag is what put it in the queue. Read is the part
    /// that matters — leaving a dismissed message unread means the unread
    /// scope re-queues it forever, and it is the behaviour Linear's
    /// mark-read gives, which is what this is modelled on.
    ///
    /// Two things this must not do, both learned from -1719 in 0.3.0:
    ///
    /// - **Never `first message … whose`.** When the filter matches nothing
    ///   Mail raises "Invalid index" (-1719), which says nothing useful.
    ///   `count of (messages … whose …)` returns 0 instead, so a miss is a
    ///   fact we can act on rather than an opaque failure.
    /// - **Never look up a bare id in the unified inbox.** Mail's `id` is
    ///   scoped to a mailbox, so the same number can mean different messages
    ///   in different accounts. Scope it to the account and mailbox the
    ///   message was found in, and keep the RFC Message-ID as the fallback
    ///   for when Mail has moved it since.
    static func markDoneScript(handle: MessageHandle) -> String {
        var lookups: [String] = []
        if let account = handle.account, !account.isEmpty,
            let mailbox = handle.mailbox, !mailbox.isEmpty {
            lookups.append(
                "(messages of mailbox \(quoted(mailbox)) of account id \(quoted(account)) whose id is \(handle.mailID))"
            )
        }
        // A 0.3.0 handle, or a message Mail has since moved: fall back to the
        // stable RFC id, then to the bare numeric id as a last resort.
        if let messageID = handle.messageID, !messageID.isEmpty {
            lookups.append(
                "(messages of inbox whose message id is \(quoted(messageID)))")
        }
        lookups.append("(messages of inbox whose id is \(handle.mailID))")

        var body = "set hits to \(lookups[0])\n"
        for lookup in lookups.dropFirst() {
            body += "    if (count of hits) is 0 then set hits to \(lookup)\n"
        }
        body += """
                if (count of hits) is 0 then error \(quoted(notFoundMessage)) number -1728
                set m to item 1 of hits
                set read status of m to true
            """
        if handle.unflag {
            body += "\n    set flagged status of m to false"
        }

        return """
            tell application "Mail"
                \(body)
            end tell
            """
    }

    /// Raised by the script itself when every lookup misses, so the reason
    /// reaching the user is this sentence rather than "-1728".
    static let notFoundMessage =
        "Inbox & Chill could not find that message in Mail any more — it may have been moved or deleted."


    /// Parses the script's output. Returns the items plus whether Mail had
    /// more messages than we asked for — which must reach
    /// `snapshotWasComplete()`, or `.remoteTruth` archives the tail.
    static func items(fromScriptOutput output: String) -> (items: [RemoteItem], truncated: Bool) {
        let records = output.components(separatedBy: recordSeparator)
        guard let first = records.first else { return ([], false) }
        let truncated = first.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let items = records.dropFirst().compactMap { item(fromRecord: $0) }
        return (items, truncated)
    }

    static func item(fromRecord record: String) -> RemoteItem? {
        let fields = record.components(separatedBy: fieldSeparator)
        guard fields.count >= 7, let mailID = Int(trim(fields[0])) else { return nil }
        // Fields 7 and 8 arrived in 0.3.1; tolerate their absence so a queue
        // written by 0.3.0 still parses.
        let account = fields.count > 7 ? trim(fields[7]) : ""
        let mailbox = fields.count > 8 ? trim(fields[8]) : ""

        let messageID = trim(fields[1])
        let subject = trim(fields[2])
        let sender = trim(fields[3])
        let isFlagged = trim(fields[5]) == "true"
        let isRead = trim(fields[6]) == "true"

        let handle = MessageHandle(
            mailID: mailID,
            messageID: messageID.isEmpty ? nil : messageID,
            unflag: isFlagged,
            account: account.isEmpty ? nil : account,
            mailbox: mailbox.isEmpty ? nil : mailbox)

        return RemoteItem(
            externalID: messageID.isEmpty ? "mail-id:\(mailID)" : messageID,
            kind: isFlagged ? "flagged" : "unread",
            title: subject.isEmpty ? "(no subject)" : subject,
            snippet: sender.isEmpty ? nil : sender,
            url: messageURL(messageID: messageID)?.absoluteString,
            actorName: displayName(fromSender: sender),
            // Mail always gives a date; an unparseable one goes to
            // `.distantPast` rather than `.now`, because `.now` beats every
            // `doneAt` and would make the row impossible to dismiss.
            occurredAt: date(fromComponents: trim(fields[4])) ?? .distantPast,
            // A flagged message is one the user singled out themselves.
            // Nothing in an inbox is a stronger signal than that.
            highSignal: isFlagged && !isRead,
            payload: handle.encoded,
            // Sender, not conversation: measured 229 of 334 items folding
            // against 104, and what folds is digests and bots. The address is
            // the key so two people called Sam stay apart and "Bandcamp" and
            // "Bandcamp <noreply@…>" stay together.
            groupKey: senderAddress(fromSender: sender),
            groupLabel: displayName(fromSender: sender))
    }

    /// The address in `Name <addr>` (or the bare address), lowercased — the
    /// part of a sender that survives a display-name change.
    static func senderAddress(fromSender sender: String) -> String? {
        let trimmed = sender.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.firstIndex(of: "<") {
            let address = trimmed[trimmed.index(after: open)...]
                .split(separator: ">", maxSplits: 1).first.map(String.init)
                ?? ""
            let cleaned = address.trimmingCharacters(in: .whitespaces).lowercased()
            return cleaned.isEmpty ? nil : cleaned
        }
        return trimmed.lowercased()
    }

    /// `message://%3c<Message-ID>%3e` opens the exact message in Mail.app —
    /// verified 2026-08-19. The angle brackets are required and must be
    /// percent-encoded.
    static func messageURL(messageID: String) -> URL? {
        let trimmed = messageID.trimmingCharacters(
            in: CharacterSet(charactersIn: "<> \t\n"))
        guard !trimmed.isEmpty else { return nil }
        guard
            let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(
                    CharacterSet(charactersIn: "-._~@!$&'()*+,;=:")))
        else { return nil }
        return URL(string: "message://%3c\(encoded)%3e")
    }

    /// `"Ada Lovelace" <ada@example.com>` → `Ada Lovelace`. Mail also hands
    /// back a bare address, which is its own best display name.
    static func displayName(fromSender sender: String) -> String? {
        let trimmed = sender.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let bracket = trimmed.firstIndex(of: "<") else { return trimmed }
        let name = trimmed[..<bracket].trimmingCharacters(
            in: CharacterSet(charactersIn: "\" \t"))
        if !name.isEmpty { return name }
        let address = trimmed[bracket...].trimmingCharacters(
            in: CharacterSet(charactersIn: "<> \t"))
        return address.isEmpty ? nil : address
    }

    /// Parses `"2026-08-19 14:32:07"` in the Mac's own calendar and time
    /// zone. The script emits components rather than a formatted date
    /// because `date received as string` is locale-dependent — it is
    /// "Wednesday, 19 August 2026 at 14:32:07" on this Mac and something
    /// else on the next one.
    static func date(fromComponents raw: String) -> Date? {
        let parts = raw.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" })
        guard parts.count == 6 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 6 else { return nil }
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers[5]
        return Calendar.current.date(from: components)
    }

    /// Rule 4: the failure that matters here is macOS refusing the Apple
    /// event, because it looks exactly like an empty inbox.
    static func explain(appleScriptError code: Int) -> String {
        switch code {
        case -1743:
            return
                "macOS won't let Inbox & Chill read Mail. Allow it under System Settings → Privacy & Security → Automation → Inbox & Chill → Mail. Until then this source will look permanently empty."
        case -600, -609:
            return
                "Mail isn't running, so there's nothing to read. Open Mail and this source fills in on the next refresh."
        case -1719:
            return
                "Mail couldn't find that message where Inbox & Chill last saw it (AppleScript error -1719). It was probably moved or deleted; the row is cleared here either way."
        case -1728:
            return
                "Mail couldn't return one of the requested properties (AppleScript error -1728). This is usually a message still downloading; it should resolve on the next refresh."
        default:
            return "Couldn't read Mail (AppleScript error \(code))."
        }
    }

    /// AppleScript string literal quoting: backslashes and double quotes.
    static func quoted(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func trim(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Execution

    /// Runs AppleScript off the actor. `NSAppleScript` blocks, and a cold
    /// Mail takes ~12 seconds — parking a cooperative-pool thread for that
    /// long would stall unrelated connectors.
    private static func runScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            scriptQueue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?
                    .executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                    // The number alone is not actionable — "-1719" cost an
                    // hour of guessing before the message turned out to say
                    // "Invalid index", which named the bug outright.
                    let detail =
                        (error[NSAppleScript.errorBriefMessage] as? String)
                        ?? (error[NSAppleScript.errorMessage] as? String) ?? "no message"
                    log.error(
                        "Mail script failed: \(code, privacy: .public) — \(detail, privacy: .public)")
                    continuation.resume(
                        throwing: AppleMailError(
                            errorDescription: explain(appleScriptError: code)))
                    return
                }
                continuation.resume(returning: result?.stringValue ?? "")
            }
        }
    }

    /// Serial: two overlapping enumerations of a cold Mail are strictly
    /// worse than one, and Mail is the bottleneck either way.
    private static let scriptQueue = DispatchQueue(
        label: "lol.bgreen.inboxandchill.apple-mail")
}
