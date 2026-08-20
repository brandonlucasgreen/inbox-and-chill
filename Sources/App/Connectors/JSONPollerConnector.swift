import Foundation

/// Generic custom source: polls any URL returning a JSON array (or an object
/// with an "items" array) and maps fields per a user-supplied mapping like
/// "id=id,title=title,url=html_url,time=created_at,body=description".
/// Auth: optional raw Authorization header from the Keychain.
actor JSONPollerConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "jsonPoller"
    nonisolated let capabilities: ConnectorCapabilities = [.remoteTruth]
    nonisolated let pollInterval: TimeInterval = 120

    private let url: URL?
    private let mapping: [String: String]

    /// Both ISO-8601 shapes a feed may send. `nil` means neither matched —
    /// callers must **not** substitute `.now`; see the throw in `fetch()`.
    nonisolated static func timestamp(from string: String) -> Date? {
        ISO8601Timestamp.date(from: string)
    }

    init(sourceID: String, urlString: String, mapping: String) {
        self.sourceID = sourceID
        self.url = URL(string: urlString)
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
        let array: [[String: Any]]
        if let a = json as? [[String: Any]] {
            array = a
        } else if let o = json as? [String: Any],
            let a = o["items"] as? [[String: Any]] {
            array = a
        } else {
            throw ConnectorError("Feed is not a JSON array (or {items: []})")
        }

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
