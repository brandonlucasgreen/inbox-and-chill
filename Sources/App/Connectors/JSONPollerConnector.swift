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

        let iso = ISO8601DateFormatter()
        return array.compactMap { obj in
            func str(_ field: String) -> String? {
                guard let key = mapping[field] else { return nil }
                if let s = obj[key] as? String { return s }
                if let n = obj[key] as? NSNumber { return n.stringValue }
                return nil
            }
            guard let id = str("id") ?? str("url"),
                let title = str("title")
            else { return nil }
            let date = str("time").flatMap { iso.date(from: $0) } ?? .now
            return RemoteItem(
                externalID: id, kind: "custom", title: title,
                snippet: str("body"), url: str("url"), occurredAt: date,
                highSignal: false)
        }
    }
}

struct ConnectorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
