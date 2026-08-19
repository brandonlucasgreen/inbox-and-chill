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
                return "No Linear API key in Keychain for source \"\(sourceID)\". Add a Personal API Key under Settings → Sources (Linear → Settings → API → Personal API keys)."
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

    // MARK: Auth

    /// The `Authorization` header value: a personal API key, sent raw. No
    /// `Bearer` prefix — that is Linear's documented shape for personal keys.
    ///
    /// A PKCE "Sign in with Linear" flow lived here until 2026-08-19 and was
    /// removed at Brandon's request. PLAN §6.9's original verdict was that
    /// the personal key "remains Linear's sanctioned personal path and is
    /// fewer steps", and it was right: OAuth still required registering your
    /// own Linear app and pasting a client ID, so it traded one paste for a
    /// longer setup and a token that expires.
    private func authorizationHeader() throws -> String {
        guard let key = Keychain.get("\(sourceID).apiKey"), !key.isEmpty else {
            throw LinearConnectorError.missingAPIKey(sourceID: sourceID)
        }
        return key
    }

    // MARK: Transport

    /// POSTs a GraphQL query/mutation and returns its decoded `data` payload,
    /// throwing a descriptive error for network failures, non-200 responses
    /// (including 429 — the engine's poll loop backs off naturally on the
    /// next interval), top-level GraphQL errors, or decode failures.
    private func execute<T: Decodable>(
        _ document: String, variables: [String: String]? = nil
    ) async throws -> T {
        let authorization = try authorizationHeader()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
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
        // `Notification` is an interface: the shared fields come straight
        // off it, and each concrete type contributes its own entity via an
        // inline fragment. Without these fragments every non-issue
        // notification arrives with no entity at all and can only be
        // described as "Linear notification".
        //
        // `DocumentNotification` has no `document` relation at all, only
        // `documentId`, so its name is resolved in a second pass below.
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
                  url
                  subtitle
                  ... on DocumentNotification {
                    documentId
                  }
                  ... on IssueNotification {
                    issue { identifier title url }
                    comment { body }
                  }
                  ... on InitiativeNotification {
                    initiative { name url }
                    initiativeUpdate { url }
                    document { title url }
                    comment { body }
                  }
                  ... on ProjectNotification {
                    project { name url }
                    projectUpdate { url }
                    document { title url }
                    comment { body }
                  }
                  ... on PullRequestNotification {
                    pullRequest { title url }
                  }
                  ... on CustomerNotification {
                    customer { name url }
                  }
                  ... on ProductAnnouncementNotification {
                    productAnnouncement { title }
                  }
                }
              }
            }
            """
        let payload: LinearNotificationsPayload = try await execute(query)
        var nodes = payload.notifications.nodes
            .filter { $0.readAt == nil && $0.snoozedUntilAt == nil && $0.archivedAt == nil }

        let documents = await resolveDocuments(for: nodes)
        for index in nodes.indices {
            if let id = nodes[index].documentId, let document = documents[id] {
                nodes[index].document = document
            }
        }
        return nodes.map(Self.mapItem)
    }

    /// Resolves the `documentId` on any `DocumentNotification` to a title
    /// and URL, keyed by id.
    ///
    /// `DocumentNotification` is the one notification type that exposes no
    /// relation to its subject, so without this a document mention can only
    /// say "Mentioned you" with no idea *where*. One extra request per poll,
    /// and only when the inbox actually holds a document notification.
    ///
    /// Best-effort by design: this is enrichment, and a failure here must
    /// not fail the poll and empty the queue. A document that can't be
    /// named still gets its own title-free phrasing and a working deep link.
    private func resolveDocuments(for nodes: [LinearNotificationNode]) async
        -> [String: LinearNotificationNode.TitledEntity]
    {
        let ids = Set(nodes.compactMap(\.documentId)).sorted()
        guard !ids.isEmpty else { return [:] }

        // `execute` carries variables as `[String: String]`, which can't
        // express `[ID!]`. JSON-encoding the ids into the document is safe —
        // the encoder escapes them, and they are Linear-issued ids echoed
        // straight back to Linear.
        let encoded = (try? JSONEncoder().encode(ids))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let query = """
            query {
              documents(filter: { id: { in: \(encoded) } }, first: \(ids.count)) {
                nodes { id title url }
              }
            }
            """
        guard let payload: LinearDocumentsPayload = try? await execute(query) else {
            return [:]
        }
        return payload.documents.nodes.reduce(into: [:]) { result, document in
            result[document.id] = .init(title: document.title, url: document.url)
        }
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

    /// Pure, network-free so the row text is unit-testable.
    nonisolated static func mapItem(_ node: LinearNotificationNode) -> RemoteItem {
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

    /// The row's headline, snippet and deep link.
    ///
    /// The row renders `actor.displayName` on its own line, so the title
    /// deliberately leaves the actor out and leads with the action and the
    /// thing it happened to: "Mentioned in Q3 Roadmap", not
    /// "amaan mentioned you in Q3 Roadmap".
    nonisolated static func describe(_ node: LinearNotificationNode) -> (
        title: String, snippet: String?, url: String?
    ) {
        // Linear's `subtitle` is the notification's body text, so it backs
        // the snippet for the types that expose no `comment` relation.
        return (
            headline(type: node.type, entity: entityName(node)),
            snippetText(node.comment?.body ?? node.subtitle),
            deepLink(node)
        )
    }

    /// How much comment body a row carries. Matched to `SlackConnector`'s
    /// cap so an opened row is the same size whatever it came from.
    static let snippetLimit = 320

    /// The row's body text, flattened into a paragraph.
    ///
    /// This kept only the first line while the row was one line tall, which
    /// was the right call then — a Linear comment's opening line is usually
    /// its point. Now that the selected row opens to a paragraph, the rest
    /// of the comment is what decides whether it needs answering, so the
    /// whole body comes through: newlines collapsed (markdown hard-wraps and
    /// blank lines would otherwise read as holes in the middle of a
    /// sentence) and capped, so one essay-length comment can't be the only
    /// thing in the panel.
    nonisolated static func snippetText(_ body: String?) -> String? {
        guard let body else { return nil }
        let flattened =
            body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flattened.count > snippetLimit else {
            return flattened.nonEmptyOrNil
        }
        return flattened.prefix(snippetLimit - 1)
            .trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The best human name for whatever the notification is about.
    ///
    /// Only public, stable entity relations are consulted. Linear's own
    /// `[Internal]` `subtitle` is deliberately *not* a candidate: against
    /// live data it holds the whole comment body, so using it here produced
    /// titles hundreds of characters long. Notifications whose subject
    /// can't be named return nil and get the standalone phrasing.
    nonisolated static func entityName(_ node: LinearNotificationNode) -> String? {
        if let issue = node.issue {
            return "\(issue.identifier): \(issue.title)".nonEmptyOrNil
        }
        // A document attached to an initiative or project is the subject of
        // the notification, so it outranks its container's name.
        if let document = node.document?.title?.nonEmptyOrNil { return document }
        if let pullRequest = node.pullRequest?.title?.nonEmptyOrNil { return pullRequest }
        if let initiative = node.initiative?.name.nonEmptyOrNil { return initiative }
        if let project = node.project?.name.nonEmptyOrNil { return project }
        if let customer = node.customer?.name.nonEmptyOrNil { return customer }
        if let announcement = node.productAnnouncement?.title?.nonEmptyOrNil {
            return announcement
        }
        return nil
    }

    /// Deep link, best target first.
    ///
    /// The notification's own `url` points at the exact comment or update
    /// and so beats the entity's canonical URL, but it is an `[Internal]`
    /// schema field; the entity URLs behind it mean losing it costs
    /// precision rather than dropping every row back to the inbox.
    nonisolated static func deepLink(_ node: LinearNotificationNode) -> String {
        node.url?.nonEmptyOrNil
            ?? node.issue?.url.nonEmptyOrNil
            ?? node.document?.url?.nonEmptyOrNil
            ?? node.pullRequest?.url?.nonEmptyOrNil
            ?? node.initiativeUpdate?.url?.nonEmptyOrNil
            ?? node.projectUpdate?.url?.nonEmptyOrNil
            ?? node.initiative?.url?.nonEmptyOrNil
            ?? node.project?.url?.nonEmptyOrNil
            ?? node.customer?.url?.nonEmptyOrNil
            ?? "https://linear.app/inbox"
    }

    /// How one family of notification types reads in the queue.
    struct Phrasing: Sendable {
        /// Text placed directly before the entity name.
        var withEntity: String
        /// Used when no name could be resolved for the entity.
        var alone: String
    }

    /// Phrasing by type suffix. Linear's type strings are
    /// `<entity><Action>` (`documentCommentMention`, `issueAssignedToYou`),
    /// so the action is the suffix and one entry covers every entity that
    /// can carry it — `Mention` handles `issueMention`, `documentMention`,
    /// `initiativeUpdateCommentMention` and the rest alike.
    ///
    /// Order matters: the first matching suffix wins, so a longer suffix
    /// must precede any shorter one it ends with (`ThreadResolved` before
    /// `Resolved`).
    private nonisolated static let phrasings: [(suffix: String, phrasing: Phrasing)] = [
        ("Mention", .init(withEntity: "Mentioned in ", alone: "Mentioned you")),
        ("NewComment", .init(withEntity: "New comment on ", alone: "New comment")),
        ("Commented", .init(withEntity: "New comment on ", alone: "New comment")),
        ("Reaction", .init(withEntity: "Reaction on ", alone: "New reaction")),
        ("AssignedToYou", .init(withEntity: "Assigned: ", alone: "Assigned to you")),
        (
            "UnassignedFromYou",
            .init(withEntity: "Unassigned: ", alone: "Unassigned from you")
        ),
        ("StatusChangedAll", .init(withEntity: "Status changed: ", alone: "Status changed")),
        ("StatusChanged", .init(withEntity: "Status changed: ", alone: "Status changed")),
        ("ThreadResolved", .init(withEntity: "Thread resolved on ", alone: "Thread resolved")),
        ("Resolved", .init(withEntity: "Resolved: ", alone: "Resolved")),
        ("Reminder", .init(withEntity: "Reminder: ", alone: "Reminder")),
        (
            "ReviewRerequested",
            .init(withEntity: "Review requested again: ", alone: "Review requested again")
        ),
        ("ReviewRequested", .init(withEntity: "Review requested: ", alone: "Review requested")),
        (
            "ChangesRequested",
            .init(withEntity: "Changes requested: ", alone: "Changes requested")
        ),
        ("ChecksFailed", .init(withEntity: "Checks failed: ", alone: "Checks failed")),
        ("Approved", .init(withEntity: "Approved: ", alone: "Approved")),
        ("Due", .init(withEntity: "Due soon: ", alone: "Due soon")),
        ("Blocking", .init(withEntity: "Blocking: ", alone: "Blocking")),
        ("Unblocked", .init(withEntity: "Unblocked: ", alone: "Unblocked")),
        ("Unsubscribed", .init(withEntity: "Unsubscribed from ", alone: "Unsubscribed")),
        ("Subscribed", .init(withEntity: "Subscribed to ", alone: "Subscribed")),
        (
            "AddedAsOwner",
            .init(withEntity: "You're now an owner of ", alone: "You're now an owner")
        ),
        (
            "AddedAsLead",
            .init(withEntity: "You're now the lead of ", alone: "You're now the lead")
        ),
        ("AddedAsMember", .init(withEntity: "Added to ", alone: "Added as a member")),
        ("AddedToTriage", .init(withEntity: "Added to triage: ", alone: "Added to triage")),
        ("AddedToView", .init(withEntity: "Added to view: ", alone: "Added to a view")),
        ("SlaBreached", .init(withEntity: "SLA breached: ", alone: "SLA breached")),
        ("SlaHighRisk", .init(withEntity: "SLA at risk: ", alone: "SLA at risk")),
        ("PriorityUrgent", .init(withEntity: "Marked urgent: ", alone: "Marked urgent")),
        (
            "MarkedAsImportant",
            .init(withEntity: "Marked important: ", alone: "Marked important")
        ),
        ("ContentChange", .init(withEntity: "Content changed: ", alone: "Content changed")),
        ("Reopened", .init(withEntity: "Reopened: ", alone: "Reopened")),
        ("Restored", .init(withEntity: "Restored: ", alone: "Restored")),
        ("Deleted", .init(withEntity: "Deleted: ", alone: "Deleted")),
        ("Moved", .init(withEntity: "Moved: ", alone: "Moved")),
    ]

    /// Turns a Linear notification type into the row's headline.
    ///
    /// A type with no explicit phrasing still has to read as prose. Linear
    /// adds types faster than it publishes them — `projectUpdateMentionPrompt`
    /// is live in the API but absent from the `OtherNotificationType` enum —
    /// so the fallback decomposes the camelCase identifier into a sentence
    /// rather than leaking it verbatim.
    nonisolated static func headline(type: String, entity: String?) -> String {
        if let match = phrasings.first(where: { type.hasSuffix($0.suffix) }) {
            guard let entity else { return match.phrasing.alone }
            return match.phrasing.withEntity + entity
        }
        let sentence = sentenceCase(type).nonEmptyOrNil ?? "Linear notification"
        guard let entity else { return sentence }
        return "\(sentence) — \(entity)"
    }

    /// `projectMilestoneThreadResolved` -> "Project milestone thread resolved".
    ///
    /// Splits only on lower-to-upper boundaries, so an acronym run stays in
    /// one piece instead of shattering into single letters.
    nonisolated static func sentenceCase(_ camelCase: String) -> String {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in camelCase {
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                words.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.map { $0.lowercased() }.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Types worth interrupting for: something is being asked of you.
    ///
    /// Listed explicitly rather than pattern-matched — the type list is
    /// knowable (Linear's `OtherNotificationType` enum plus the per-type
    /// issue scalars), and a substring test quietly mis-files new ones.
    ///
    /// Reactions stay quiet: they are pleasant, not actionable. That also
    /// preserves today's behaviour, despite the old comment claiming
    /// otherwise — its `contains("reaction to your")` test never matched,
    /// because no Linear type string contains that phrase.
    private nonisolated static let highSignalTypes: Set<String> = [
        // Someone typed your name.
        "issueMention", "issueCommentMention",
        "documentMention", "documentCommentMention",
        "initiativeMention", "initiativeCommentMention",
        "initiativeUpdateMention", "initiativeUpdateCommentMention",
        "projectMention", "projectCommentMention",
        "projectUpdateMention", "projectUpdateCommentMention",
        "projectMilestoneMention", "projectMilestoneCommentMention",
        "teamUpdateMention", "teamUpdateCommentMention",
        "pullRequestMention", "pullRequestCommentMention",
        "agentConversationMention",
        // Work handed to you.
        "issueAssignedToYou", "issueAddedToTriage",
        "triageResponsibilityIssueAddedToTriage",
        "documentAddedAsOwner", "initiativeAddedAsOwner",
        "customerAddedAsOwner", "projectAddedAsLead",
        // Someone is waiting on your review.
        "pullRequestReviewRequested", "pullRequestReviewRerequested",
        "pullRequestChangesRequested",
        // Time-critical, on work that is already yours.
        "issueDue", "issueSlaBreached",
    ]

    nonisolated static func isHighSignal(_ type: String) -> Bool {
        if highSignalTypes.contains(type) { return true }
        // Linear ships mention variants ahead of the published schema —
        // `projectUpdateMentionPrompt` is live in the API but absent from
        // the enum. A type that names a mention is unambiguous, so the old
        // substring test survives as the residual case rather than letting
        // new mention types silently drop to low signal.
        return type.contains("Mention")
    }

    private static func parseISO8601(_ string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601Whole.date(from: string)
    }
}

extension String {
    /// `nil` rather than `""`, so an optional-chained blank field falls
    /// through to the next candidate.
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
