import Foundation

/// Polls the authenticated user's Linear inbox (`notifications`) and
/// write-throughs done/snooze via `notificationArchive` /
/// `notificationUpdate`. Linear's inbox is itself remote truth — archiving
/// elsewhere removes it from `notifications`, so `.remoteTruth` applies.
actor LinearConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "linear"
    nonisolated let capabilities: ConnectorCapabilities = [.markDone, .remoteSnooze, .remoteTruth]
    nonisolated let pollInterval: TimeInterval = 30

    private static let endpoint = URL(string: "https://api.linear.app/graphql")!

    // ISO8601DateFormatter is documented thread-safe; it just lacks a
    // Sendable annotation.
    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) static let iso8601Whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    enum LinearConnectorError: Error, LocalizedError, CustomStringConvertible, Sendable {
        case missingAPIKey(sourceID: String)
        case transport(String)
        case httpError(status: Int, body: String)
        case graphQLErrors([String])
        case decodingFailed(String)
        case operationFailed(String)

        var description: String { errorDescription ?? "Linear connector error" }
        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let sourceID):
                return "No Linear API key in Keychain for \"\(sourceID).apiKey\". Add a Personal API Key under Settings → Linear."
            case .transport(let detail):
                return "Linear request failed: \(detail)"
            case .httpError(let status, let body):
                return "Linear API returned HTTP \(status): \(body.prefix(300))"
            case .graphQLErrors(let messages):
                return "Linear GraphQL error: \(messages.joined(separator: "; "))"
            case .decodingFailed(let detail):
                return "Failed to decode Linear response: \(detail)"
            case .operationFailed(let detail):
                return detail
            }
        }
    }

    // MARK: Transport

    private func apiKey() throws -> String {
        guard let key = Keychain.get("\(sourceID).apiKey"), !key.isEmpty else {
            throw LinearConnectorError.missingAPIKey(sourceID: sourceID)
        }
        return key
    }

    /// POSTs a GraphQL query/mutation and returns its decoded `data` payload,
    /// throwing a descriptive error for network failures, non-200 responses
    /// (including 429 — the engine's poll loop backs off naturally on the
    /// next interval), top-level GraphQL errors, or decode failures.
    private func execute<T: Decodable>(_ document: String, variables: [String: String]? = nil) async throws -> T {
        let key = try apiKey()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GraphQLRequestBody(query: document, variables: variables))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LinearConnectorError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw LinearConnectorError.transport("no HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LinearConnectorError.httpError(status: http.statusCode, body: body)
        }

        let decoded: GraphQLResponse<T>
        do {
            decoded = try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
        } catch {
            throw LinearConnectorError.decodingFailed(String(describing: error))
        }
        if let errors = decoded.errors, !errors.isEmpty {
            throw LinearConnectorError.graphQLErrors(errors.map(\.message))
        }
        guard let payload = decoded.data else {
            throw LinearConnectorError.decodingFailed("response had no data and no errors")
        }
        return payload
    }

    // MARK: Connector

    func fetch() async throws -> [RemoteItem] {
        let query = """
            query {
              notifications(first: 50) {
                nodes {
                  id
                  type
                  readAt
                  snoozedUntilAt
                  archivedAt
                  createdAt
                  actor { displayName }
                  ... on IssueNotification {
                    issue { identifier title url }
                    comment { body }
                  }
                }
              }
            }
            """
        let payload: LinearNotificationsPayload = try await execute(query)
        return payload.notifications.nodes
            .filter { $0.readAt == nil && $0.snoozedUntilAt == nil && $0.archivedAt == nil }
            .map(Self.mapItem)
    }

    func markDone(externalID: String, payload: Data?) async throws {
        let mutation = """
            mutation ArchiveNotification($id: String!) {
              notificationArchive(id: $id) { success }
            }
            """
        let result: LinearArchiveNotificationPayload = try await execute(
            mutation, variables: ["id": externalID])
        guard result.notificationArchive.success else {
            throw LinearConnectorError.operationFailed(
                "notificationArchive(id: \(externalID)) returned success=false")
        }
    }

    func snooze(externalID: String, until: Date, payload: Data?) async throws {
        let mutation = """
            mutation SnoozeNotification($id: String!, $snoozedUntilAt: DateTime!) {
              notificationUpdate(id: $id, input: { snoozedUntilAt: $snoozedUntilAt }) { success }
            }
            """
        let result: LinearUpdateNotificationPayload = try await execute(
            mutation,
            variables: [
                "id": externalID,
                "snoozedUntilAt": Self.iso8601Fractional.string(from: until),
            ])
        guard result.notificationUpdate.success else {
            throw LinearConnectorError.operationFailed(
                "notificationUpdate(id: \(externalID)) returned success=false")
        }
    }

    // MARK: Mapping

    private static func mapItem(_ node: LinearNotificationNode) -> RemoteItem {
        let occurredAt = parseISO8601(node.createdAt) ?? .now
        let (title, snippet, url) = describe(node)
        return RemoteItem(
            externalID: node.id,
            kind: node.type,
            title: title,
            snippet: snippet,
            url: url,
            actorName: node.actor?.displayName,
            occurredAt: occurredAt,
            highSignal: isHighSignal(node.type),
            payload: nil)
    }

    private static func describe(_ node: LinearNotificationNode) -> (
        title: String, snippet: String?, url: String?
    ) {
        guard let issue = node.issue else {
            return ("\(node.type): Linear notification", nil, "https://linear.app/inbox")
        }
        let issueRef = "\(issue.identifier): \(issue.title)"
        let title: String
        switch node.type {
        case "issueMention":
            title = "Mentioned in \(issueRef)"
        case "issueAssignedToYou":
            title = "Assigned: \(issueRef)"
        case "issueNewComment":
            title = "New comment on \(issueRef)"
        default:
            title = "\(node.type): \(issueRef)"
        }
        let snippet = node.comment?.body.flatMap { body -> String? in
            body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        return (title, snippet?.isEmpty == false ? snippet : nil, issue.url)
    }

    /// Simple heuristic: anything that reads as a mention, an assignment to
    /// you, or a reaction on your content is worth surfacing loudly;
    /// everything else (new comments, status changes, etc.) is not.
    private static func isHighSignal(_ type: String) -> Bool {
        type.contains("Mention") || type.contains("AssignedToYou")
            || type.localizedCaseInsensitiveContains("reaction to your")
    }

    private static func parseISO8601(_ string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601Whole.date(from: string)
    }
}
