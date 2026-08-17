import Foundation

/// Polls Campsite's INTERNAL v1 API (the one campsite's own web client uses —
/// NOT the public v2 bot API) for the current member's actionable
/// notifications and pending follow-ups.
///
/// v1 routes are org-scoped: every route we use lives under
/// `scope "/organizations/:org_slug"` in api/config/routes.rb (that scope
/// opens at the `resources :public_projects` line and closes ~380 lines
/// later, right after `resources :data_exports`). `ConnectorCatalog`'s
/// "campsite" descriptor today only has `baseURL`/`token` fields — it needs
/// an `orgSlug` field added (non-secret) for this connector to be
/// configurable from Settings. See init below.
///
/// Auth: Campsite mounts Doorkeeper (`use_doorkeeper` in routes.rb) and
/// `Api::V1::BaseController` reads `doorkeeper_token`, so a standard OAuth2
/// bearer token via `Authorization: Bearer <token>` is correct.
actor CampsiteConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "campsite"
    nonisolated let capabilities: ConnectorCapabilities = [.markDone, .remoteTruth]
    nonisolated let pollInterval: TimeInterval = 60

    private let baseURL: String
    private let orgSlug: String

    /// - Parameters:
    ///   - baseURL: The self-hosted instance root (e.g. "https://campsite.buffer.com").
    ///     Campsite serves both the v1 API and the web app from this same
    ///     host (see `Campsite.app_url` in api/lib/campsite.rb — no separate
    ///     API subdomain), so `baseURL` doubles as the prefix for item URLs.
    ///   - orgSlug: The organization slug used to scope every v1 route
    ///     (`/v1/organizations/:org_slug/...`). Not present in
    ///     ConnectorCatalog today — needs to be added as a new, non-secret
    ///     "orgSlug" field on the "campsite" descriptor.
    init(sourceID: String = "campsite", baseURL: String, orgSlug: String) {
        self.sourceID = sourceID
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.orgSlug = orgSlug
    }

    struct CampsiteConnectorError: LocalizedError, CustomStringConvertible {
        var errorDescription: String?
        // SyncEngine surfaces poll failures via `String(describing: error)`
        // rather than `localizedDescription`; conform to both so the
        // message renders cleanly either way.
        var description: String { errorDescription ?? "Campsite connector error" }
    }

    // MARK: Decoding
    //
    // Campsite's v1 serializers (Blueprinter) return many more fields than
    // modeled here; we decode only what RemoteItem needs. Field names match
    // the API's snake_case JSON keys verbatim (no CodingKeys / decoding
    // strategy), matching this app's other connectors.

    /// The `api_page` envelope shared by every v1 index endpoint:
    /// `{ data: [...], next_cursor, prev_cursor }` — see
    /// `ApiSerializer.api_page` in api/app/serializers/api_serializer.rb.
    /// `next_cursor` is the last item's `public_id`; pass it back as `after`
    /// to fetch the next page (api/lib/cursor_pagination.rb).
    private struct Page<T: Decodable>: Decodable {
        var data: [T]
        var next_cursor: String?
    }

    /// Mirrors `NotificationTargetSerializer` — always a Post, Note, or Call
    /// for the notifications we fetch below, since the `home_inbox` scope
    /// (api/app/models/notification.rb) restricts `target_type` to those
    /// three.
    private struct TargetRef: Decodable {
        var id: String
        var type: String
        var title: String?
    }

    /// Mirrors the fields we use from `NotificationSerializer`
    /// (api/app/serializers/notification_serializer.rb).
    private struct APINotification: Decodable {
        var id: String
        var created_at: String
        var summary: String?
        var reason: String
        var target: TargetRef?
    }

    /// Mirrors `FollowUpSubjectSerializer` — the thing the follow-up was
    /// actually placed on (may be a Post/Note/Call directly, or a Comment).
    private struct FollowUpSubjectRef: Decodable {
        var id: String
        var type: String
        var title: String?
    }

    /// Mirrors the fields we use from `FollowUpSerializer`
    /// (api/app/serializers/follow_up_serializer.rb). `target` there is
    /// `notification_target`, which — per `FollowUp#notification_target` in
    /// api/app/models/follow_up.rb — resolves a Comment subject to its
    /// parent Post/Note/Call, same as notifications above.
    private struct APIFollowUp: Decodable {
        var id: String
        var show_at: String
        var subject: FollowUpSubjectRef?
        var target: TargetRef?
    }

    // MARK: fetch

    func fetch() async throws -> [RemoteItem] {
        // GET /v1/organizations/:org_slug/members/me/notifications
        // (api/app/controllers/api/v1/notifications_controller.rb#index).
        // `filter=grouped_home` -> kept_notifications.unarchived.home_inbox;
        // `unread=true` -> .unread. Matches the "actionable, personal inbox"
        // shape we want (targets are always Post/Note/Call).
        let notifications = try await fetchAllPages(
            path: "/v1/organizations/\(orgSlug)/members/me/notifications",
            query: [("unread", "true"), ("filter", "grouped_home")],
            as: APINotification.self)

        // GET /v1/organizations/:org_slug/follow_ups
        // (api/app/controllers/api/v1/follow_ups_controller.rb#index) ->
        // current_organization_membership.unshown_follow_ups — already
        // filtered to not-yet-shown, so no extra query params needed.
        let followUps = try await fetchAllPages(
            path: "/v1/organizations/\(orgSlug)/follow_ups",
            query: [],
            as: APIFollowUp.self)

        return notifications.map(makeRemoteItem) + followUps.map(makeRemoteItem)
    }

    /// Follows `next_cursor` until exhausted or `maxPages` is hit (100/page,
    /// so 10 pages = up to 1,000 items — comfortably more than an unread
    /// inbox should ever hold).
    private func fetchAllPages<T: Decodable>(
        path: String, query: [(String, String)], as type: T.Type
    ) async throws -> [T] {
        guard let token = Keychain.get("\(sourceID).token") else {
            throw CampsiteConnectorError(errorDescription: "Campsite: no access token configured for source \(sourceID).")
        }

        var results: [T] = []
        var cursor: String?
        var pagesFetched = 0
        let maxPages = 10

        repeat {
            var items = query + [("limit", "100")]
            if let cursor { items.append(("after", cursor)) }

            guard var components = URLComponents(string: "\(baseURL)\(path)") else {
                throw CampsiteConnectorError(errorDescription: "Campsite: could not construct URL for \(path).")
            }
            components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
            guard let url = components.url else {
                throw CampsiteConnectorError(errorDescription: "Campsite: could not construct URL for \(path).")
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CampsiteConnectorError(errorDescription: "Campsite: non-HTTP response from \(path).")
            }

            guard http.statusCode == 200 else {
                let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable body>"
                switch http.statusCode {
                case 401:
                    throw CampsiteConnectorError(errorDescription: "Campsite: unauthorized (401) — check the access token. \(bodySnippet)")
                case 403:
                    throw CampsiteConnectorError(errorDescription: "Campsite: forbidden (403) fetching \(path) — token may lack access to org '\(orgSlug)'. \(bodySnippet)")
                case 404:
                    throw CampsiteConnectorError(errorDescription: "Campsite: not found (404) at \(path) — check the org slug '\(orgSlug)' and base URL. \(bodySnippet)")
                default:
                    throw CampsiteConnectorError(errorDescription: "Campsite: unexpected status \(http.statusCode) from \(path). \(bodySnippet)")
                }
            }

            let page: Page<T>
            do {
                page = try JSONDecoder().decode(Page<T>.self, from: data)
            } catch {
                let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable body>"
                throw CampsiteConnectorError(errorDescription: "Campsite: failed to decode response from \(path): \(error). \(bodySnippet)")
            }

            results.append(contentsOf: page.data)
            cursor = page.next_cursor
            pagesFetched += 1
        } while cursor != nil && pagesFetched < maxPages

        return results
    }

    // MARK: markDone

    func markDone(externalID: String, payload: Data?) async throws {
        guard let token = Keychain.get("\(sourceID).token") else {
            throw CampsiteConnectorError(errorDescription: "Campsite: no access token configured for source \(sourceID).")
        }

        var components: URLComponents
        if externalID.hasPrefix(Self.followUpPrefix) {
            let id = String(externalID.dropFirst(Self.followUpPrefix.count))
            // DELETE /v1/organizations/:org_slug/follow_ups/:id
            // (api/app/controllers/api/v1/follow_ups_controller.rb#destroy).
            guard let c = URLComponents(string: "\(baseURL)/v1/organizations/\(orgSlug)/follow_ups/\(id)") else {
                throw CampsiteConnectorError(errorDescription: "Campsite: could not construct URL to mark follow-up \(id) done.")
            }
            components = c
        } else {
            // DELETE /v1/organizations/:org_slug/members/me/notifications/:id
            // (notifications_controller.rb#destroy). `archive_by=id` archives
            // only this exact notification; the controller's default
            // (`archive_by=target`) would also archive every other
            // notification sharing the same target, which would silently
            // clear sibling RemoteItems we haven't marked done ourselves.
            guard var c = URLComponents(string: "\(baseURL)/v1/organizations/\(orgSlug)/members/me/notifications/\(externalID)") else {
                throw CampsiteConnectorError(errorDescription: "Campsite: could not construct URL to mark notification \(externalID) done.")
            }
            c.queryItems = [URLQueryItem(name: "archive_by", value: "id")]
            components = c
        }

        guard let url = components.url else {
            throw CampsiteConnectorError(errorDescription: "Campsite: could not construct URL to mark \(externalID) done.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CampsiteConnectorError(errorDescription: "Campsite: non-HTTP response marking \(externalID) done.")
        }
        guard http.statusCode == 204 else {
            let bodySnippet = String(data: data.prefix(500), encoding: .utf8) ?? "<unreadable body>"
            switch http.statusCode {
            case 401:
                throw CampsiteConnectorError(errorDescription: "Campsite: unauthorized (401) marking \(externalID) done. \(bodySnippet)")
            case 403:
                throw CampsiteConnectorError(errorDescription: "Campsite: forbidden (403) marking \(externalID) done. \(bodySnippet)")
            case 404:
                throw CampsiteConnectorError(errorDescription: "Campsite: not found (404) marking \(externalID) done — it may already be resolved. \(bodySnippet)")
            default:
                throw CampsiteConnectorError(errorDescription: "Campsite: unexpected status \(http.statusCode) marking \(externalID) done. \(bodySnippet)")
            }
        }
    }

    // MARK: Mapping

    private static let followUpPrefix = "followup-"

    /// mentions and other directly-personal reasons are high signal;
    /// passive subscription/status-change reasons are not. Reason values
    /// come from `Notification.reasons` in api/app/models/notification.rb.
    private static let highSignalReasons: Set<String> = [
        "mention", "feedback_requested", "added", "permission_granted",
    ]

    /// Web app path for a Post/Note/Call target, matching each model's own
    /// `#path` method (e.g. `Post#path` -> "/#{org.slug}/posts/#{public_id}"
    /// in api/app/models/post.rb; Note and Call follow the same shape with
    /// "notes"/"calls").
    private static func webPathSegment(forTargetType type: String) -> String? {
        switch type {
        case "Post": return "posts"
        case "Note": return "notes"
        case "Call": return "calls"
        default: return nil
        }
    }

    private func itemURL(target: TargetRef?) -> String? {
        guard let target, let segment = Self.webPathSegment(forTargetType: target.type) else { return nil }
        return "\(baseURL)/\(orgSlug)/\(segment)/\(target.id)"
    }

    private func makeRemoteItem(from notification: APINotification) -> RemoteItem {
        RemoteItem(
            externalID: notification.id,
            kind: notification.reason,
            title: notification.summary ?? notification.target?.title ?? "Campsite notification",
            url: itemURL(target: notification.target),
            occurredAt: Self.parseDate(notification.created_at) ?? .now,
            highSignal: Self.highSignalReasons.contains(notification.reason))
    }

    private func makeRemoteItem(from followUp: APIFollowUp) -> RemoteItem {
        let subjectTitle = followUp.subject?.title ?? followUp.target?.title ?? "item"

        // `Comment#path` (api/app/models/comment.rb) is
        // `subject.path(org) + "#comment-#{public_id}"` — the parent
        // Post/Note/Call's page, with a fragment pointing at the comment.
        // `target` here is already the resolved parent
        // (`FollowUp#notification_target`), so we only need to add the
        // fragment when the follow-up's actual subject was a Comment.
        var url = itemURL(target: followUp.target)
        if followUp.subject?.type == "Comment", let commentID = followUp.subject?.id, url != nil {
            url! += "#comment-\(commentID)"
        }

        return RemoteItem(
            externalID: "\(Self.followUpPrefix)\(followUp.id)",
            kind: "follow_up",
            title: "Follow up: \(subjectTitle)",
            url: url,
            occurredAt: Self.parseDate(followUp.show_at) ?? .now,
            highSignal: true)
    }

    /// Rails' default JSON time encoding includes millisecond fractional
    /// seconds (e.g. "2024-06-01T12:34:56.789Z"); fall back to a formatter
    /// without fractional seconds in case a field ever omits them.
    private nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func parseDate(_ string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601.date(from: string)
    }
}
