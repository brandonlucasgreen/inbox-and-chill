import Foundation

/// Generic custom source: polls any URL returning a JSON array (or an object
/// with an "items" array) and maps fields per a user-supplied mapping like
/// "id=id,title=title,url=html_url,time=created_at,body=description".
/// Auth: optional raw Authorization header from the Keychain.
///
/// **`root=` is what makes this cover real APIs.** Until 2026-09-04 the list
/// had to be the whole response or sit under the key `items`, and a survey of
/// nine candidate services found *not one* that obliged: Stripe nests under
/// `data`, PagerDuty `incidents`, Jira `issues`, Vercel `deployments`, Asana
/// `data`. One optional term — `root=data` — turns each of those into a
/// read-only source with no connector, which is the escape hatch PLAN §6.10
/// promises actually working. See `docs/source-candidates.md`.
actor JSONPollerConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "jsonPoller"
    nonisolated let capabilities: ConnectorCapabilities = [.remoteTruth]
    nonisolated let pollInterval: TimeInterval = 120

    private let url: URL?
    /// The scheme of a URL that parsed but was refused (anything other than
    /// http/https). Surfaced in `fetch()` as a named, actionable error rather
    /// than the generic "Invalid feed URL" a nil `url` produces.
    private let rejectedScheme: String?
    private let mapping: [String: String]

    /// Both ISO-8601 shapes a feed may send. `nil` means neither matched —
    /// callers must **not** substitute `.now`; see the throw in `fetch()`.
    nonisolated static func timestamp(from string: String) -> Date? {
        ISO8601Timestamp.date(from: string)
    }

    /// The schemes a JSON feed URL may use. Non-http(s) is refused up front:
    /// the app is unsandboxed, so `file://` would read a local file into
    /// memory on every poll, and no other scheme is useful to a JSON poller.
    /// (The HTTP-status guard below already stops a `file://` response from
    /// being parsed — `URLSession` returns `NSURLResponse`, not
    /// `HTTPURLResponse` — but rejecting the scheme gives a named error
    /// instead of a confusing "Feed returned HTTP -1".)
    nonisolated static func accept(
        urlString: String
    ) -> (url: URL?, rejectedScheme: String?) {
        guard let parsed = URL(string: urlString) else {
            return (nil, nil)
        }
        if let scheme = parsed.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        {
            return (parsed, nil)
        }
        return (nil, parsed.scheme)
    }

    /// Where the list lives in the response.
    ///
    /// - No `root=`: a bare JSON array, or `{"items": […]}` — the two shapes
    ///   this connector has always taken, unchanged so every existing feed
    ///   keeps working.
    /// - `root=data`: the array under that key.
    /// - `root=result.items`: a dotted path, walked key by key, because
    ///   nesting twice is common enough (`{"result": {"items": […]}}`) that
    ///   leaving it out would send those feeds back to needing a connector.
    ///
    /// Every failure names the keys the feed *does* have. A mapping is
    /// per-feed and typed by hand, so "no array at data" with the real key
    /// list beside it is the difference between a fix and a guess (rule 5).
    nonisolated static func rows(
        in json: Any, root: String?
    ) throws -> [[String: Any]] {
        guard let root, !root.isEmpty else {
            if let array = json as? [[String: Any]] { return array }
            if let object = json as? [String: Any],
                let array = object["items"] as? [[String: Any]]
            {
                return array
            }
            throw ConnectorError(
                "Feed is not a JSON array, and has no \"items\" array. "
                    + describe(json)
                    + " If the list is under another key, add it to the "
                    + "mapping as `root=<key>`.")
        }
        var node: Any = json
        var walked: [String] = []
        for key in root.split(separator: ".").map(String.init) {
            guard let object = node as? [String: Any] else {
                throw ConnectorError(
                    "Mapping says `root=\(root)`, but \(walkedLabel(walked)) "
                        + "is not a JSON object, so there is no \"\(key)\" "
                        + "inside it.")
            }
            guard let next = object[key] else {
                throw ConnectorError(
                    "Mapping says `root=\(root)`, but \(walkedLabel(walked)) "
                        + "has no \"\(key)\". " + describe(node))
            }
            node = next
            walked.append(key)
        }
        if let array = node as? [[String: Any]] { return array }
        // An array of strings or numbers is a real mistake to make and reads
        // nothing like "not an array" — say which it is.
        if node is [Any] {
            throw ConnectorError(
                "\"\(root)\" is an array, but not of JSON objects, so there "
                    + "are no fields to map.")
        }
        throw ConnectorError(
            "\"\(root)\" is not an array. " + describe(node))
    }

    /// "the response" for the top level, then the path walked so far — so the
    /// two failures above read as sentences rather than as jargon.
    private nonisolated static func walkedLabel(_ walked: [String]) -> String {
        walked.isEmpty ? "the response" : "\"\(walked.joined(separator: "."))\""
    }

    /// Names what the feed actually sent, so a mapping can be corrected
    /// without curling it by hand.
    nonisolated static func describe(_ json: Any) -> String {
        if let object = json as? [String: Any] {
            let keys = object.keys.sorted().prefix(12)
            guard !keys.isEmpty else { return "The object is empty." }
            return "Keys present: \(keys.joined(separator: ", "))."
        }
        if let array = json as? [Any] {
            return "The feed sent an array of \(array.count) values."
        }
        return "The feed sent a single \(type(of: json)) value."
    }

    init(sourceID: String, urlString: String, mapping: String) {
        self.sourceID = sourceID
        let decision = Self.accept(urlString: urlString)
        self.url = decision.url
        self.rejectedScheme = decision.rejectedScheme
        var map: [String: String] = [:]
        for pair in mapping.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                map[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        self.mapping = map
    }

    func fetch() async throws -> [RemoteItem] {
        if let scheme = rejectedScheme {
            throw ConnectorError(
                "Feed URL uses the \"\(scheme)\" scheme, but a JSON poller " +
                "only supports http and https. Use a URL starting with " +
                "http:// or https://.")
        }
        guard let url else {
            throw ConnectorError("Invalid feed URL")
        }
        var request = URLRequest(url: url)
        if let auth = Keychain.get("\(sourceID).authHeader"), !auth.isEmpty {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200
        else {
            throw ConnectorError(
                "Feed returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let json = try JSONSerialization.jsonObject(with: data)
        let array = try Self.rows(in: json, root: mapping["root"])

        return try array.compactMap { obj in
            func str(_ field: String) -> String? {
                guard let key = mapping[field] else { return nil }
                if let s = obj[key] as? String { return s }
                if let n = obj[key] as? NSNumber { return n.stringValue }
                return nil
            }
            guard let id = str("id") ?? str("url"),
                let title = str("title")
            else { return nil }
            // An unparseable timestamp is surfaced, not swallowed (rule 4).
            // `.now` is the one value that must never be substituted here:
            // this connector has `.remoteTruth` but not `.markDone`, so a
            // dismissed item stays in every snapshot, and a fresh `.now` is
            // always later than `doneAt` — `Store.resurrectIfNeeded` revives
            // it on the very next poll. The item becomes undismissable.
            // Failing the whole cycle with a named reason is the deliberate
            // trade: a mapping is per-feed, so a parse failure is nearly
            // always the mapping rather than one odd row, and a visible
            // error beats a queue the user cannot clear.
            var occurredAt = Date.now
            if let raw = str("time") {
                guard let parsed = Self.timestamp(from: raw) else {
                    throw ConnectorError(
                        """
                        Feed field "\(mapping["time"] ?? "time")" is not an \
                        ISO-8601 timestamp: "\(raw.prefix(60))". Point `time=` \
                        at a field formatted like "2026-08-19T12:34:56Z" or \
                        "2026-08-19T12:34:56.789Z".
                        """)
                }
                occurredAt = parsed
            }
            return RemoteItem(
                externalID: id, kind: "custom", title: title,
                snippet: str("body"), url: str("url"), occurredAt: occurredAt,
                highSignal: false)
        }
    }
}

struct ConnectorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
