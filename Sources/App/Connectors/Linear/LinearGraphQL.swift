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

/// One node from `notifications.nodes`.
///
/// `Notification` is a GraphQL *interface*. `id`, `type`, `actor`, `url`
/// and `subtitle` are declared on the interface itself and so are present
/// on every node; the entity relations below arrive from the per-type
/// inline fragments in `LinearConnector.fetch()` and are simply absent on
/// the concrete types that don't declare them, which Optional decoding
/// handles for free.
///
/// Every property carries a default so tests can build a node with only
/// the fields under test.
struct LinearNotificationNode: Decodable, Sendable {
    struct Actor: Decodable, Sendable {
        var displayName: String?
    }
    /// `Issue` — the one entity with a human-facing short code (`CORE-42`).
    struct Issue: Decodable, Sendable {
        var identifier: String = ""
        var title: String = ""
        var url: String = ""
    }
    struct Comment: Decodable, Sendable {
        var body: String?
    }
    /// `Initiative`, `Project`, `Customer` — entities named by `name`.
    struct NamedEntity: Decodable, Sendable {
        var name: String = ""
        var url: String?
    }
    /// `Document`, `PullRequest`, `ProductAnnouncement` — named by `title`.
    struct TitledEntity: Decodable, Sendable {
        var title: String?
        var url: String?
    }
    /// `InitiativeUpdate` / `ProjectUpdate`. An update has no name of its
    /// own — it borrows its parent's — so it only contributes a deep link.
    struct UpdateEntity: Decodable, Sendable {
        var url: String?
    }

    var id: String = ""
    var type: String = ""
    var readAt: String?
    var snoozedUntilAt: String?
    var archivedAt: String?
    var createdAt: String = ""
    var actor: Actor?

    /// Interface fields, both marked `[Internal]` in Linear's schema.
    /// `url` is the notification's target link. `subtitle` is *not* a name —
    /// against live data it holds the comment body ("Simon Heaton mentioned
    /// you: Generally aligned here @Mike…"), so it feeds the snippet only.
    var url: String?
    var subtitle: String?

    /// `DocumentNotification` carries no `document` relation — only this id.
    /// `LinearConnector.fetch()` resolves it and fills in `document`.
    var documentId: String?

    // Per-type entity relations, in the order their fragments appear in
    // the query.
    var issue: Issue?
    var comment: Comment?
    var document: TitledEntity?
    var initiative: NamedEntity?
    var initiativeUpdate: UpdateEntity?
    var project: NamedEntity?
    var projectUpdate: UpdateEntity?
    var pullRequest: TitledEntity?
    var customer: NamedEntity?
    var productAnnouncement: TitledEntity?
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

// MARK: - documents query payload

/// Second-pass lookup that turns the `documentId` on a
/// `DocumentNotification` into a name and a link.
struct LinearDocumentsPayload: Decodable, Sendable {
    struct Documents: Decodable, Sendable {
        var nodes: [Document]
    }
    struct Document: Decodable, Sendable {
        var id: String
        var title: String?
        var url: String?
    }
    var documents: Documents
}
