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
    ///
    /// The triage fields past `url` feed `ItemContext` chips on the expanded
    /// row (D). They ride the same notifications query — Linear rate-limits
    /// by complexity and these are scalar fields plus one small nested list,
    /// so the enrichment costs no extra request.
    struct Issue: Decodable, Sendable {
        var identifier: String = ""
        var title: String = ""
        var url: String = ""
        /// 0 = none, 1 = urgent, 2 = high, 3 = normal, 4 = low.
        var priority: Int?
        /// Linear's own human phrasing for `priority` ("Urgent").
        var priorityLabel: String?
        /// A date-only string, `2026-08-28`.
        var dueDate: String?
        var labels: Labels?
        var project: ProjectEntity?
    }
    struct Labels: Decodable, Sendable {
        var nodes: [Label] = []
    }
    struct Label: Decodable, Sendable {
        var name: String = ""
        /// Hex like `#f2c94c`; drawn as the chip's dot.
        var color: String?
    }
    /// A project as context for the expanded row: the blurb and target date
    /// on top of the name/url `NamedEntity` carries.
    struct ProjectEntity: Decodable, Sendable {
        var name: String = ""
        var url: String?
        var description: String?
        /// Date-only string, `2026-09-05`.
        var targetDate: String?
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
    /// own — it borrows its parent's — so its row contributes a deep link;
    /// `body` and `health` are requested for project updates only and feed
    /// the D expansion, where the update text *is* the context. (Found live
    /// 2026-08-23: most project notifications are about an update, and a
    /// project with no description left them with nothing to show.)
    struct UpdateEntity: Decodable, Sendable {
        var url: String?
        var body: String?
        /// `onTrack` / `atRisk` / `offTrack`.
        var health: String?
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
    var project: ProjectEntity?
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
