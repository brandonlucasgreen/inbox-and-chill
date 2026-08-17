import Foundation

// MARK: - Dynamic JSON

/// A `Sendable`, dynamically-navigable JSON value.
///
/// Slack's Web API and Socket Mode payloads are wide, sparsely-populated and
/// vary by event type — modelling every shape as a `Decodable` struct would be
/// a lot of code that still breaks the first time Slack adds a field. This
/// gives us `payload["event"]["channel"].string` ergonomics while staying
/// strictly `Sendable`, which `[String: Any]` (the `JSONSerialization` shape)
/// is not — and Swift 6 will not let a non-`Sendable` value cross into an
/// actor. Typed `Decodable` structs are still used where a shape is stable.
enum SlackJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SlackJSON])
    case object([String: SlackJSON])
}

extension SlackJSON: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SlackJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SlackJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognised JSON value")
        }
    }
}

extension SlackJSON {
    /// Missing keys yield `.null` rather than `nil` so lookups chain freely.
    subscript(key: String) -> SlackJSON {
        guard case .object(let object) = self, let value = object[key] else {
            return .null
        }
        return value
    }

    subscript(index: Int) -> SlackJSON {
        guard case .array(let items) = self, items.indices.contains(index) else {
            return .null
        }
        return items[index]
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A non-empty string, or nil — Slack loves returning `""` for "unset".
    var nonEmptyString: String? {
        guard let value = string, !value.isEmpty else { return nil }
        return value
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value): return value == "true" ? true : (value == "false" ? false : nil)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var int: Int? { double.map { Int($0) } }

    var array: [SlackJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var isNull: Bool { self == .null }
}

// MARK: - Errors

struct SlackError: LocalizedError, CustomStringConvertible {
    var errorDescription: String?
    /// Slack's machine-readable `error` string (`missing_scope`, `no_reaction`,
    /// `rate_limited`…) when the failure came from an `ok: false` response.
    var slackCode: String?

    // SyncEngine surfaces failures via `String(describing:)` rather than
    // `localizedDescription`; conform to both so either renders cleanly.
    var description: String { errorDescription ?? "Slack connector error" }
}

// MARK: - Timestamps

/// Slack message timestamps are strings like `"1699999999.000100"` — unique
/// per message per channel, and ordered by numeric value (never string value,
/// which breaks across second-digit boundaries).
enum SlackTS {
    static func date(_ ts: String?) -> Date? {
        guard let ts, let seconds = Double(ts) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        (Double(lhs) ?? 0) > (Double(rhs) ?? 0)
    }
}

// MARK: - Web API

/// Thin Slack Web API client. One instance per token: the user `xoxp` token
/// for everything the connector reads and writes, and a throwaway instance on
/// the app-level `xapp` token just to open a Socket Mode connection.
///
/// Every method is POSTed form-encoded, which the whole Web API accepts, so
/// there's no per-method GET/POST bookkeeping.
struct SlackAPI: Sendable {
    let token: String

    private static let base = "https://slack.com/api/"
    /// Slack asks clients to ack/retry politely; one retry is enough to ride
    /// out an incidental burst without turning a rate limit into a hot loop.
    private static let maxRateLimitRetries = 1

    /// Calls `method` and returns the full response object. Throws when the
    /// transport fails or Slack replies `ok: false`.
    func call(_ method: String, _ params: [String: String] = [:]) async throws -> SlackJSON {
        try await perform(method, params, attempt: 0)
    }

    /// Best-effort variant for enrichment calls (display names, permalinks,
    /// `reactions.list`) where a failure — a missing scope, a channel we've
    /// been removed from — should degrade the item, not kill the connection.
    func tryCall(_ method: String, _ params: [String: String] = [:]) async -> SlackJSON? {
        try? await perform(method, params, attempt: 0)
    }

    private func perform(
        _ method: String, _ params: [String: String], attempt: Int
    ) async throws -> SlackJSON {
        guard let url = URL(string: Self.base + method) else {
            throw SlackError(errorDescription: "Slack: bad method name \(method).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(params).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SlackError(errorDescription: "Slack \(method): non-HTTP response.")
        }

        if http.statusCode == 429 {
            guard attempt < Self.maxRateLimitRetries else {
                throw SlackError(
                    errorDescription: "Slack \(method): rate limited (429) after retry.",
                    slackCode: "rate_limited")
            }
            let advertised = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
            try await Task.sleep(for: .seconds(min(max(advertised, 1), 60)))
            return try await perform(method, params, attempt: attempt + 1)
        }

        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<unreadable body>"
            throw SlackError(
                errorDescription: "Slack \(method): HTTP \(http.statusCode). \(snippet)")
        }

        let value = try JSONDecoder().decode(SlackJSON.self, from: data)
        guard value["ok"].bool == true else {
            let code = value["error"].string ?? "unknown_error"
            throw SlackError(
                errorDescription: "Slack \(method): \(code).", slackCode: code)
        }
        return value
    }

    private static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        .joined(separator: "&")
    }
}
