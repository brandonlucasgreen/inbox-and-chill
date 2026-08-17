import Foundation

// MARK: - Request envelope

/// Standard GraphQL POST body. All our mutation arguments travel as string
/// variables (ids, ISO8601 timestamps), so a `[String: String]` map is
/// enough — no need for a heterogeneous `AnyEncodable`.
struct GraphQLRequestBody: Encodable {
    var query: String
    var variables: [String: String]? = nil
}

// MARK: - Response envelope

/// Wraps the top-level `data`/`errors` shape common to every GraphQL
/// response. `T` is the operation-specific payload under `data`.
struct GraphQLResponse<T: Decodable>: Decodable {
    var data: T?
    var errors: [GraphQLErrorMessage]?
}

struct GraphQLErrorMessage: Decodable, Sendable {
    var message: String
}

// MARK: - notifications query payload

struct LinearNotificationsPayload: Decodable, Sendable {
    struct Notifications: Decodable, Sendable {
        var nodes: [LinearNotificationNode]
    }
    var notifications: Notifications
}

/// One node from `notifications.nodes`. Fields from the `IssueNotification`
/// inline fragment (`issue`, `comment`) are simply absent/nil on other
/// notification types (e.g. oauth client approvals), which Optional
/// decoding handles for free.
struct LinearNotificationNode: Decodable, Sendable {
    struct Actor: Decodable, Sendable {
        var displayName: String?
    }
    struct Issue: Decodable, Sendable {
        var identifier: String
        var title: String
        var url: String
    }
    struct Comment: Decodable, Sendable {
        var body: String?
    }

    var id: String
    var type: String
    var readAt: String?
    var snoozedUntilAt: String?
    var archivedAt: String?
    var createdAt: String
    var actor: Actor?
    var issue: Issue?
    var comment: Comment?
}

// MARK: - Mutation payloads

struct LinearSuccessPayload: Decodable, Sendable {
    var success: Bool
}

struct LinearArchiveNotificationPayload: Decodable, Sendable {
    var notificationArchive: LinearSuccessPayload
}

struct LinearUpdateNotificationPayload: Decodable, Sendable {
    var notificationUpdate: LinearSuccessPayload
}
