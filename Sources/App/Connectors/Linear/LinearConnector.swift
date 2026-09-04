import Foundation

/// Polls the authenticated user's Linear inbox (`notifications`) and
/// write-throughs done/snooze via `notificationArchive` /
/// `notificationUpdate`. Linear's inbox is itself remote truth — archiving
/// elsewhere removes it from `notifications`, so `.remoteTruth` applies.
actor LinearConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "linear"
    nonisolated let capabilities: ConnectorCapabilities = [
        .markDone, .remoteSnooze, .remoteTruth, .providesContext,
    ]
    nonisolated let pollInterval: TimeInterval = 30

    private static let endpoint = URL(string: "https://api.linear.app/graphql")!

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
                return "No Linear API key in Keychain for source \"\(sourceID)\". Add a Personal API Key under Settings → Sources (Linear → Settings → Security & Access → Personal API keys)."
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
                    issue {
                      identifier title url
                      priority priorityLabel dueDate
                      labels { nodes { name color } }
                      project { name url description targetDate }
                    }
                    comment { body }
                  }
                  ... on InitiativeNotification {
                    initiative { name url }
                    initiativeUpdate { url }
                    document { title url }
                    comment { body }
                  }
                  ... on ProjectNotification {
                    project { name url description targetDate }
                    projectUpdate { url body health }
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
                "snoozedUntilAt": ISO8601Timestamp.string(from: until),
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
        let grouping = grouping(node)
        return RemoteItem(
            externalID: node.id,
            kind: node.type,
            title: title,
            snippet: snippet,
            url: url,
            actorName: node.actor?.displayName,
            occurredAt: occurredAt,
            highSignal: isHighSignal(node.type),
            // Context is built eagerly — the fields ride the same query —
            // and stored here, so `context()` needs no network at all.
            // `Store.update` refreshes payload every poll, keeping it fresh.
            payload: contextData(for: node),
            groupKey: grouping?.key, groupLabel: grouping?.label)
    }

    /// What a notification folds under: its **issue** when it has one, else
    /// its **project** (project updates, documents, initiatives).
    ///
    /// Issue first, measured: 468 of 576 rows in the live store carry an
    /// issue key, and a comment and a status change on `EPD-1873` are one
    /// thing while two issues in one project are two. Grouping everything by
    /// project would fold harder and hide your issue behind a project name.
    /// The project key is its URL rather than its name, so a renamed project
    /// keeps its fold.
    nonisolated static func grouping(
        _ node: LinearNotificationNode
    ) -> (key: String, label: String)? {
        if let issue = node.issue, !issue.identifier.isEmpty {
            let label =
                issue.title.isEmpty
                ? issue.identifier : "\(issue.identifier) · \(issue.title)"
            return ("issue:\(issue.identifier)", label)
        }
        if let project = node.project ?? node.issue?.project,
            !project.name.isEmpty
        {
            return ("project:\(project.url ?? project.name)", project.name)
        }
        return nil
    }

    // MARK: Context (D expansion)

    /// Decodes the context this connector wrote into the payload at poll
    /// time. Never touches the network — an item from an older build simply
    /// has no context until the next poll rewrites its payload.
    func context(externalID: String, payload: Data?) async throws -> ItemContext? {
        guard let payload else { return nil }
        return try? JSONDecoder().decode(ItemContext.self, from: payload)
    }

    nonisolated static func contextData(for node: LinearNotificationNode) -> Data? {
        guard let context = context(for: node), !context.isEmpty else { return nil }
        return try? JSONEncoder().encode(context)
    }

    /// Chips (priority, due date, labels) and a project blurb, from whatever
    /// the notification's entity carries. Pure so it's unit-testable.
    nonisolated static func context(for node: LinearNotificationNode) -> ItemContext? {
        var chips: [ItemContext.Chip] = []
        var project: LinearNotificationNode.ProjectEntity?

        if let issue = node.issue {
            if let priority = issue.priority, priority > 0,
                let label = issue.priorityLabel, !label.isEmpty {
                chips.append(.init(
                    systemImage: priority == 1 ? "exclamationmark.2" : "flag",
                    text: label,
                    tint: priority == 1 ? .orange : .neutral))
            }
            if let due = formatDay(issue.dueDate) {
                chips.append(.init(systemImage: "calendar", text: "Due \(due)"))
            }
            for label in issue.labels?.nodes ?? [] where !label.name.isEmpty {
                chips.append(.init(dotHex: label.color, text: label.name))
            }
            project = issue.project
        }
        if let own = node.project { project = own }

        var context = ItemContext(chips: chips)
        // A project-update notification's real content is the update itself
        // — health and body — not the project's (often empty) description.
        // The description stays as the fallback blurb for everything else.
        if let health = healthChip(node.projectUpdate?.health) {
            context.chips.append(health)
        }
        if let update = node.projectUpdate?.body, !update.isEmpty {
            context.blurbLabel = "Project update"
                + (project.map { " · \($0.name)" } ?? "")
            context.blurb = String(update.prefix(280))
        } else if let project, let description = project.description,
            !description.isEmpty {
            var label = "Project · \(project.name)"
            if let ships = formatDay(project.targetDate) {
                label += " · ships \(ships)"
            }
            context.blurbLabel = label
            context.blurb = String(description.prefix(280))
        }
        return context.isEmpty ? nil : context
    }

    /// Linear's three project-health states, in the traffic-light colors
    /// their own UI uses.
    nonisolated static func healthChip(_ health: String?) -> ItemContext.Chip? {
        switch health {
        case "onTrack":
            return .init(systemImage: "checkmark.circle", text: "On track", tint: .green)
        case "atRisk":
            return .init(systemImage: "exclamationmark.triangle", text: "At risk", tint: .orange)
        case "offTrack":
            return .init(systemImage: "xmark.circle", text: "Off track", tint: .red)
        default:
            return nil
        }
    }

    /// `2026-08-28` → `Fri Aug 28`. Linear's date-only fields carry no time
    /// zone, so this parses in the user's calendar rather than UTC — a due
    /// date is a day, and shifting it across midnight would rename the day.
    nonisolated static func formatDay(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "EEE MMM d"
        return out.string(from: date)
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

    /// How much comment body a row carries. Matched to `SlackText`'s cap so
    /// `D` reaches the end of a Linear comment the way it reaches the end of
    /// a Slack message — at 320 it stopped at an ellipsis nothing could open
    /// (CLAUDE.md recorded that as a known gap until 2026-09-04). Affordable
    /// because `ExpandingText.clampedPrefix` lays out only the visible lines
    /// for every row but the selected one.
    static let snippetLimit = 4_000

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
        ISO8601Timestamp.date(from: string)
    }
}

extension String {
    /// `nil` rather than `""`, so an optional-chained blank field falls
    /// through to the next candidate.
    fileprivate var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
