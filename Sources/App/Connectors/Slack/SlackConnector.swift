import Foundation

/// Slack, as a push connector (PLAN.md §6.1).
///
/// Seeds unread DM/MPIM state over the Web API, then holds a Socket Mode
/// WebSocket open and maintains the picture incrementally. Three item kinds:
///
/// - `dm` — an unread DM or group DM, one item per conversation (not per
///   message), cleared when Slack's own read-state says you've caught up.
/// - `mention` — a `<@you>` in a channel, one item per message.
/// - `emoji_save` — you reacted with the configured save emoji (default
///   📌 `:pushpin:`), Slack's Saved-for-Later having no API at all.
///
/// ## Why this never emits `.snapshot`
///
/// `.remoteTruth` makes the store auto-archive anything absent from a
/// snapshot. That's the behaviour we want for DMs and the reason the
/// capability is declared — but a snapshot is only safe if it can enumerate
/// *every* live item, and mentions can't be enumerated: Slack has no
/// "my mentions" API, so they exist only in this connector's memory of events
/// it happened to witness. Slack also retires each Socket Mode connection
/// every ~10 minutes with a `disconnect` envelope, and the SyncEngine restarts
/// `run()` after every disconnect or error — so "snapshot at seed" would in
/// practice mean "snapshot every ten minutes", silently archiving every
/// mention and save the user hadn't triaged yet. Dropping real items is the
/// exact failure this app exists to prevent.
///
/// Instead the seed emits `.upsert` for unread conversations and an explicit
/// `.clear` for every conversation it enumerated that is *read* — which
/// reconciles DM state exactly as precisely as a snapshot would, because
/// `users.conversations` returns the complete set of possible `dm-` ids, while
/// leaving mentions and saves untouched. See `seed(emit:)`.
///
/// ## Read-state without `*_marked`
///
/// The `im_marked` / `channel_marked` / `mpim_marked` / `group_marked` events
/// are RTM-era and are *not* part of the Events API surface Socket Mode
/// delivers, so "you read it in Slack, it clears here" cannot rely on them.
/// They're handled if they ever arrive, but the load-bearing mechanism is
/// `readStateLoop` — a 90-second `conversations.info` check scoped to only the
/// channels currently holding items (usually a handful of calls).
actor SlackConnector: Connector {
    nonisolated let sourceID: String
    nonisolated let sourceKind = "slack"
    nonisolated let capabilities: ConnectorCapabilities = [.markDone, .remoteTruth, .push]
    /// Unused — `.push` makes the SyncEngine skip interval polling entirely.
    nonisolated let pollInterval: TimeInterval = 45

    /// Normalised reaction name (no colons, no skin tone) that saves a message.
    private let saveEmoji: String

    // MARK: Connection state

    private var api: SlackAPI?
    private var selfUserID = ""
    private var selfUserName = ""
    private var teamID = ""

    // MARK: Caches (populated once, reused for item titles)

    private var userNames: [String: String] = [:]
    private var channelNames: [String: String] = [:]
    /// IM channel id → the other person's user id.
    private var imPartners: [String: String] = [:]

    // MARK: The live picture

    /// Unread conversations, keyed by channel id.
    private var unreadDMs: [String: RemoteItem] = [:]
    /// Channel id → message ts → mention item.
    private var mentions: [String: [String: RemoteItem]] = [:]
    /// External id → emoji-save item.
    private var saves: [String: RemoteItem] = [:]
    /// Newest message ts we've seen per channel — what `conversations.mark`
    /// marks up to, and what read-state comparisons measure against.
    private var latestTS: [String: String] = [:]

    /// How often to re-check read state for channels holding items.
    private static let readStateInterval: Duration = .seconds(90)
    /// Full-seed cadence when running without an app-level token. Slower than
    /// the read-state check because a seed re-enumerates conversations.
    private static let pollOnlySeedInterval: Duration = .seconds(300)
    /// Concurrency cap on seed `conversations.info` fan-out (rate-limit hygiene).
    private static let seedConcurrency = 5

    init(sourceID: String = "slack", saveEmoji: String = "pushpin") {
        self.sourceID = sourceID
        let normalised = Self.normalizeEmoji(saveEmoji)
        self.saveEmoji = normalised.isEmpty ? "pushpin" : normalised
    }

    // MARK: - Connector

    /// Push connectors are driven entirely by `run(emit:)`; the SyncEngine
    /// never polls one. This returns the connector's current in-memory picture
    /// rather than `[]` purely defensively: `fetch()` results are reconciled as
    /// a snapshot, and with `.remoteTruth` an empty array would archive the
    /// user's whole Slack queue if anything ever called it by mistake.
    func fetch() async throws -> [RemoteItem] {
        let all =
            Array(unreadDMs.values)
            + mentions.values.flatMap { $0.values }
            + Array(saves.values)
        return all.sorted { $0.occurredAt > $1.occurredAt }
    }

    func markDone(externalID: String, payload: Data?) async throws {
        let api = try requireAPI()
        guard let ref = Self.reference(externalID: externalID, payload: payload) else {
            throw SlackError(
                errorDescription: "Slack: don't know how to complete \(externalID).")
        }

        switch ref.kind {
        case .dm:
            // Mark the conversation read up to the newest message we know of.
            var ts = latestTS[ref.channel]
            if ts == nil,
                let history = await api.tryCall(
                    "conversations.history", ["channel": ref.channel, "limit": "1"]) {
                ts = history["messages"][0]["ts"].string
            }
            guard let ts else {
                throw SlackError(
                    errorDescription:
                        "Slack: no known message in \(ref.channel) to mark read.")
            }
            _ = try await api.call("conversations.mark", ["channel": ref.channel, "ts": ts])
            unreadDMs.removeValue(forKey: ref.channel)

        case .mention(let ts):
            // `conversations.mark` moves last_read to exactly this message, so
            // anything newer in the channel stays unread.
            _ = try await api.call("conversations.mark", ["channel": ref.channel, "ts": ts])
            mentions[ref.channel]?.removeValue(forKey: ts)

        case .save(let ts):
            // Removing our own reaction *is* the un-save.
            do {
                _ = try await api.call(
                    "reactions.remove",
                    ["name": saveEmoji, "channel": ref.channel, "timestamp": ts])
            } catch let error as SlackError where error.slackCode == "no_reaction" {
                // Already gone (removed in Slack, or a double-tap here).
            }
            saves.removeValue(forKey: externalID)
        }
    }

    // MARK: - Run loop

    func run(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {
        emit(.status(.connecting))
        do {
            let appToken = try await connect()
            try await seed(emit: emit)

            guard let appToken else {
                // User token only. Channel mentions are unavailable — Slack
                // has no polling API for them (see `seed`) — but DM unreads,
                // emoji saves and read-state auto-clear are all pollable, so
                // the source still works. This loop stands in for the socket.
                emit(.status(.ok(.now)))
                try await pollOnlyLoop(emit: emit)
                return
            }

            let socket = try await SlackSocket.open(appToken: appToken)
            defer { socket.close() }
            emit(.status(.ok(.now)))

            // Two children: the socket reader, and the read-state safety net.
            // Whichever finishes first ends this run; the SyncEngine restarts
            // us after 5s.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    try await self.readLoop(socket: socket, emit: emit)
                }
                group.addTask { [self] in
                    await self.readStateLoop(emit: emit)
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            if error is URLError {
                // Transient network trouble reads as reconnecting, not broken.
                emit(.status(.connecting))
            } else {
                emit(.status(.error(String(describing: error))))
            }
        }
    }

    /// Names the problem with a pasted user token, or `nil` if it looks right.
    ///
    /// Worth checking before spending a round trip, because Slack's own error
    /// for the wrong token kind is opaque and the tokens are easy to mix up —
    /// the app-management page offers several, only one of which works here.
    ///
    /// `nonisolated static` so it's testable without a Keychain.
    nonisolated static func userTokenProblem(_ token: String) -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return "No user token configured." }
        if token.hasPrefix("xoxe.") || token.hasPrefix("xoxe-") {
            return
                "That's an app configuration token (it starts with “xoxe.”), which only works with Slack's App Manifest API and expires 12 hours after you generate it — it can't call the Web API at all. You want the User OAuth Token from your app's OAuth & Permissions page, which starts with “xoxp-”. (The same prefix also appears on rotation-enabled tokens, which expire every 12 hours too and can't be refreshed without your app's client secret — so if you enabled token rotation, you'll need a new app: Slack won't let you turn it back off.)"
        }
        if token.hasPrefix("xoxb-") {
            return
                "That's a bot token (“xoxb-”). This connector reads *your* account — mentions, DMs, read state — so it needs the User OAuth Token from OAuth & Permissions, starting with “xoxp-”."
        }
        if token.hasPrefix("xapp-") {
            return
                "That's the app-level token (“xapp-”) — it belongs in the App-Level Token field, not this one. The user token starts with “xoxp-”."
        }
        if !token.hasPrefix("xoxp-") {
            return
                "That doesn't look like a Slack user token. Expected one starting with “xoxp-”, from your app's OAuth & Permissions page."
        }
        return nil
    }

    /// Resolves tokens, identifies us, and returns the app-level token — or
    /// `nil` when only a user token is configured. That is a supported,
    /// deliberately degraded mode (no channel mentions), not an error: it
    /// halves the setup to one paste for anyone who doesn't want to enable
    /// Socket Mode.
    private func connect() async throws -> String? {
        guard let userToken = Keychain.get("\(sourceID).userToken"), !userToken.isEmpty else {
            throw SlackError(
                errorDescription:
                    "Slack: no user token (xoxp-…) configured for source \(sourceID).")
        }
        if let problem = Self.userTokenProblem(userToken) {
            throw SlackError(errorDescription: "Slack: \(problem)")
        }
        let api = SlackAPI(token: userToken)
        self.api = api

        let auth = try await api.call("auth.test")
        guard let userID = auth["user_id"].nonEmptyString else {
            throw SlackError(errorDescription: "Slack: auth.test returned no user_id.")
        }
        selfUserID = userID
        selfUserName = auth["user"].string ?? ""
        teamID = auth["team_id"].string ?? ""

        let appToken = Keychain.get("\(sourceID).appToken")
        return (appToken?.isEmpty == false) ? appToken : nil
    }

    /// Degraded run loop for a user-token-only install: keeps read-state and
    /// the pollable item kinds fresh in place of the Socket Mode reader.
    private func pollOnlyLoop(
        emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) async throws {
        var sinceFullSeed: Duration = .zero
        while !Task.isCancelled {
            try await Task.sleep(for: Self.readStateInterval)
            await reconcileReadState(emit: emit)

            sinceFullSeed += Self.readStateInterval
            if sinceFullSeed >= Self.pollOnlySeedInterval {
                sinceFullSeed = .zero
                try await seed(emit: emit)
            }
        }
    }

    private func readLoop(
        socket: SlackSocket, emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) async throws {
        while !Task.isCancelled {
            let envelope = try await socket.nextEnvelope()
            // Ack before doing any work — Slack redelivers after 3s.
            if let envelopeID = envelope.envelopeID {
                try? await socket.ack(envelopeID)
            }

            switch envelope.type {
            case "hello":
                emit(.status(.ok(.now)))
            case "disconnect":
                // Routine: Slack retires connections every ~10 minutes.
                emit(.status(.connecting))
                return
            case "events_api":
                await handle(event: envelope.payload["event"], emit: emit)
            default:
                break  // interactive / slash_commands: not our surface.
            }
        }
    }

    /// Periodically re-checks Slack's read state for channels that currently
    /// hold items, because Socket Mode does not deliver `*_marked` events.
    /// Deliberately non-throwing: a hiccup here must not tear down the socket.
    private func readStateLoop(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.readStateInterval) } catch { return }
            await reconcileReadState(emit: emit)
        }
    }

    // MARK: - Seed

    /// Enumerates conversations and reconciles DM unread state.
    ///
    /// Channels contribute nothing here. Slack has no API for "messages that
    /// mention me", and walking `conversations.history` for every channel to
    /// look for `<@me>` would be dozens of calls per seed for a mediocre
    /// result — so channel mentions are detected live from events only, and
    /// mentions posted before the app launched are not shown.
    /// `users.conversations` does hand us every channel's name for free, which
    /// pre-warms the cache mention titles need.
    private func seed(emit: @escaping @Sendable (ConnectorEvent) -> Void) async throws {
        guard let api else { return }

        var dmRefs: [DMRef] = []
        for conversation in try await listConversations(api: api) {
            guard let id = conversation["id"].nonEmptyString else { continue }
            if conversation["is_im"].bool == true {
                if let user = conversation["user"].nonEmptyString { imPartners[id] = user }
                dmRefs.append(DMRef(id: id, isMPIM: false))
            } else if conversation["is_mpim"].bool == true {
                if let name = conversation["name"].nonEmptyString {
                    channelNames[id] = prettyMPIMName(name)
                }
                dmRefs.append(DMRef(id: id, isMPIM: true))
            } else if let name = conversation["name"].nonEmptyString {
                channelNames[id] = name
            }
        }

        var upserts: [RemoteItem] = []
        var clears: [String] = []
        for state in await unreadStates(api: api, refs: dmRefs) {
            if state.unread, let ts = state.latestTS {
                latestTS[state.channelID] = ts
                let item = await makeDMItem(
                    channelID: state.channelID, isMPIM: state.isMPIM,
                    text: state.latestText, ts: ts)
                unreadDMs[state.channelID] = item
                upserts.append(item)
            } else {
                unreadDMs.removeValue(forKey: state.channelID)
                // Read conversations are cleared explicitly. Because we
                // enumerated every im/mpim, this is a complete accounting of
                // `dm-` ids — the precision a snapshot would have given us,
                // without snapshot's collateral damage to mentions/saves.
                clears.append("dm-\(state.channelID)")
            }
        }

        if !upserts.isEmpty { emit(.upsert(upserts)) }
        if !clears.isEmpty { emit(.clear(clears)) }

        await seedEmojiSaves(api: api, emit: emit)
    }

    private func listConversations(api: SlackAPI) async throws -> [SlackJSON] {
        var conversations: [SlackJSON] = []
        var cursor: String?
        // Bounded: 10 × 200 covers any realistic membership, and guarantees we
        // can't spin on a misbehaving cursor.
        for _ in 0..<10 {
            var params = [
                "types": "im,mpim,public_channel,private_channel",
                "exclude_archived": "true",
                "limit": "200",
            ]
            if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
            let response = try await api.call("users.conversations", params)
            conversations += response["channels"].array ?? []
            cursor = response["response_metadata"]["next_cursor"].nonEmptyString
            if cursor == nil { break }
        }
        return conversations
    }

    private struct DMRef: Sendable {
        var id: String
        var isMPIM: Bool
    }

    private struct DMState: Sendable {
        var channelID: String
        var isMPIM: Bool
        var unread: Bool
        var latestTS: String?
        var latestText: String?
    }

    /// Fans out `conversations.info` across DM conversations, at most
    /// `seedConcurrency` in flight.
    private func unreadStates(api: SlackAPI, refs: [DMRef]) async -> [DMState] {
        guard !refs.isEmpty else { return [] }
        var states: [DMState] = []
        states.reserveCapacity(refs.count)

        await withTaskGroup(of: DMState.self) { group in
            var next = 0
            func addNext() {
                guard next < refs.count else { return }
                let ref = refs[next]
                next += 1
                group.addTask { await Self.dmState(api: api, ref: ref) }
            }
            for _ in 0..<min(Self.seedConcurrency, refs.count) { addNext() }
            for await state in group {
                states.append(state)
                addNext()
            }
        }
        return states
    }

    /// `static`, so it's non-isolated and safe to call from task-group
    /// children without re-entering the actor per conversation.
    private static func dmState(api: SlackAPI, ref: DMRef) async -> DMState {
        var state = DMState(channelID: ref.id, isMPIM: ref.isMPIM, unread: false)
        guard let response = await api.tryCall("conversations.info", ["channel": ref.id])
        else { return state }

        let channel = response["channel"]
        let lastRead = channel["last_read"].nonEmptyString
        state.latestTS = channel["latest"]["ts"].nonEmptyString
        state.latestText = channel["latest"]["text"].nonEmptyString

        // `unread_count_display` is the authority (it already discounts our
        // own messages and joins/leaves). Older/edge responses omit it, so
        // fall back to comparing the newest message against last_read.
        if let unread = channel["unread_count_display"].int {
            state.unread = unread > 0
        } else if let latest = state.latestTS, let lastRead {
            state.unread = SlackTS.isNewer(latest, than: lastRead)
        }

        // Only unread conversations are worth a history call for the snippet.
        if state.unread, state.latestTS == nil || state.latestText == nil,
            let history = await api.tryCall(
                "conversations.history", ["channel": ref.id, "limit": "1"]) {
            let message = history["messages"][0]
            state.latestTS = message["ts"].nonEmptyString ?? state.latestTS
            state.latestText = message["text"].nonEmptyString ?? state.latestText
            if state.latestTS != nil, let lastRead, channel["unread_count_display"].int == nil {
                state.unread = SlackTS.isNewer(state.latestTS!, than: lastRead)
            }
        }
        return state
    }

    /// Re-derives emoji-saves from `reactions.list` so saves made while the app
    /// was closed still land in the queue. Best-effort: needs `reactions:read`,
    /// and silently does nothing if the app wasn't granted it.
    private func seedEmojiSaves(
        api: SlackAPI, emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) async {
        var cursor: String?
        var items: [RemoteItem] = []
        for _ in 0..<5 {
            var params = ["user": selfUserID, "limit": "100", "full": "true"]
            if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
            guard let response = await api.tryCall("reactions.list", params) else { return }

            for entry in response["items"].array ?? [] {
                guard entry["type"].string == "message",
                    let channel = entry["channel"].nonEmptyString
                else { continue }
                let message = entry["message"]
                guard let ts = message["ts"].nonEmptyString else { continue }

                let isSaved = (message["reactions"].array ?? []).contains { reaction in
                    Self.normalizeEmoji(reaction["name"].string ?? "") == saveEmoji
                        && (reaction["users"].array ?? []).contains { $0.string == selfUserID }
                }
                guard isSaved else { continue }

                var permalink = message["permalink"].nonEmptyString
                if permalink == nil {
                    permalink = await api.tryCall(
                        "chat.getPermalink", ["channel": channel, "message_ts": ts]
                    )?["permalink"].nonEmptyString
                }
                let item = makeSaveItem(
                    channel: channel, ts: ts, text: message["text"].string,
                    permalink: permalink)
                saves[item.externalID] = item
                items.append(item)
            }

            cursor = response["response_metadata"]["next_cursor"].nonEmptyString
            if cursor == nil { break }
        }
        if !items.isEmpty { emit(.upsert(items)) }
    }

    // MARK: - Events

    private func handle(
        event: SlackJSON, emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) async {
        switch event["type"].string {
        case "message":
            await handleMessage(event, emit: emit)
        case "reaction_added":
            await handleReaction(event, added: true, emit: emit)
        case "reaction_removed":
            await handleReaction(event, added: false, emit: emit)
        case "im_marked", "mpim_marked", "channel_marked", "group_marked":
            // RTM-era; handled opportunistically in case they ever arrive.
            handleMarked(event, emit: emit)
        default:
            break
        }
    }

    private func handleMessage(
        _ event: SlackJSON, emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) async {
        guard let channel = event["channel"].nonEmptyString,
            let ts = event["ts"].nonEmptyString
        else { return }

        // Only genuine new arrivals. `message_changed` / `message_deleted` /
        // `channel_join` carry no author and must never mint an item.
        // `file_share` is included deliberately: a DM that is just a screenshot
        // is still a DM, and missing items is worse than an empty snippet.
        if let subtype = event["subtype"].nonEmptyString,
            !["thread_broadcast", "file_share"].contains(subtype) {
            return
        }

        let author = event["user"].nonEmptyString
        let text = event["text"].string
        let channelType = event["channel_type"].string ?? ""
        if channelType == "app_home" { return }

        if latestTS[channel].map({ SlackTS.isNewer(ts, than: $0) }) ?? true {
            latestTS[channel] = ts
        }

        if channelType == "im" || channelType == "mpim" {
            guard author != selfUserID else {
                // We replied, so we've read it. Slack agrees.
                if unreadDMs.removeValue(forKey: channel) != nil {
                    emit(.clear(["dm-\(channel)"]))
                }
                return
            }
            let item = await makeDMItem(
                channelID: channel, isMPIM: channelType == "mpim", text: text, ts: ts)
            unreadDMs[channel] = item
            emit(.upsert([item]))
            return
        }

        // Channels: only a literal @-mention of us. `@here`/`@channel`/
        // user-group mentions are deliberately out — they're the noise this
        // app is supposed to spare you.
        guard author != selfUserID, let text, text.contains("<@\(selfUserID)>") else { return }
        let item = await makeMentionItem(channel: channel, ts: ts, text: text, event: event)
        mentions[channel, default: [:]][ts] = item
        emit(.upsert([item]))
    }

    private func handleReaction(
        _ event: SlackJSON, added: Bool,
        emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) async {
        guard event["user"].string == selfUserID,
            Self.normalizeEmoji(event["reaction"].string ?? "") == saveEmoji,
            event["item"]["type"].string == "message",
            let channel = event["item"]["channel"].nonEmptyString,
            let ts = event["item"]["ts"].nonEmptyString
        else { return }

        let externalID = "save-\(channel)-\(ts)"
        guard added else {
            saves.removeValue(forKey: externalID)
            emit(.clear([externalID]))
            return
        }

        guard let api else { return }
        let permalink = await api.tryCall(
            "chat.getPermalink", ["channel": channel, "message_ts": ts]
        )?["permalink"].nonEmptyString

        // The reaction event carries no message text; fetch just that message.
        var text: String?
        if let history = await api.tryCall(
            "conversations.history",
            [
                "channel": channel, "latest": ts, "oldest": ts,
                "inclusive": "true", "limit": "1",
            ]) {
            text = history["messages"][0]["text"].string
        }

        let item = makeSaveItem(channel: channel, ts: ts, text: text, permalink: permalink)
        saves[item.externalID] = item
        emit(.upsert([item]))
    }

    private func handleMarked(
        _ event: SlackJSON, emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) {
        guard let channel = event["channel"].nonEmptyString else { return }
        // A marked event *is* a read signal, so a missing ts means "all read".
        clearRead(channel: channel, upTo: event["ts"].nonEmptyString, emit: emit)
    }

    private func reconcileReadState(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {
        guard let api else { return }
        let channels = Set(unreadDMs.keys).union(
            mentions.filter { !$0.value.isEmpty }.map(\.key))
        guard !channels.isEmpty else { return }

        for channel in channels.sorted() {
            guard let response = await api.tryCall("conversations.info", ["channel": channel]),
                // Without a last_read we know nothing — never clear on a guess.
                let lastRead = response["channel"]["last_read"].nonEmptyString
            else { continue }
            clearRead(channel: channel, upTo: lastRead, emit: emit)
        }
    }

    /// Clears whatever `channel`'s read marker has now overtaken.
    private func clearRead(
        channel: String, upTo readTS: String?,
        emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) {
        var cleared: [String] = []

        if unreadDMs[channel] != nil {
            let caughtUp =
                readTS == nil || latestTS[channel] == nil
                || !SlackTS.isNewer(latestTS[channel]!, than: readTS!)
            if caughtUp {
                unreadDMs.removeValue(forKey: channel)
                cleared.append("dm-\(channel)")
            }
        }

        if var channelMentions = mentions[channel], !channelMentions.isEmpty {
            for (ts, item) in channelMentions
            where readTS == nil || !SlackTS.isNewer(ts, than: readTS!) {
                channelMentions.removeValue(forKey: ts)
                cleared.append(item.externalID)
            }
            mentions[channel] = channelMentions
        }

        if !cleared.isEmpty { emit(.clear(cleared)) }
    }

    // MARK: - Item builders

    private func makeDMItem(
        channelID: String, isMPIM: Bool, text: String?, ts: String
    ) async -> RemoteItem {
        let name = await dmName(channelID: channelID, isMPIM: isMPIM)
        return RemoteItem(
            externalID: "dm-\(channelID)",
            kind: "dm",
            title: "DM: \(name)",
            snippet: Self.truncate(renderText(text), 100),
            url: deepLink(channel: channelID),
            actorName: isMPIM ? nil : name,
            occurredAt: SlackTS.date(ts) ?? .now,
            highSignal: true,
            payload: Self.payload(channel: channelID, ts: ts))
    }

    private func makeMentionItem(
        channel: String, ts: String, text: String, event: SlackJSON
    ) async -> RemoteItem {
        let who: String
        if let author = event["user"].nonEmptyString {
            who = await displayName(userID: author)
        } else {
            who =
                event["username"].nonEmptyString
                ?? event["bot_profile"]["name"].nonEmptyString ?? "A bot"
        }
        let channelLabel = await channelName(channel)
        return RemoteItem(
            externalID: "mention-\(channel)-\(ts)",
            kind: "mention",
            title: "\(who) mentioned you in #\(channelLabel)",
            snippet: Self.truncate(renderText(text), 100),
            url: deepLink(channel: channel, message: ts),
            actorName: who,
            occurredAt: SlackTS.date(ts) ?? .now,
            highSignal: true,
            payload: Self.payload(channel: channel, ts: ts))
    }

    private func makeSaveItem(
        channel: String, ts: String, text: String?, permalink: String?
    ) -> RemoteItem {
        let body = Self.truncate(renderText(text), 80) ?? "message"
        return RemoteItem(
            externalID: "save-\(channel)-\(ts)",
            kind: "emoji_save",
            title: "Saved: \(body)",
            snippet: nil,
            // Permalinks are https and hand off to the Slack app; unlike our
            // slack:// links they still work if Slack isn't installed.
            url: permalink ?? deepLink(channel: channel, message: ts),
            actorName: nil,
            occurredAt: SlackTS.date(ts) ?? .now,
            highSignal: false,
            payload: Self.payload(channel: channel, ts: ts))
    }

    /// `slack://` opens the native client and jumps straight to the message,
    /// which is what we want from a triage queue — the https form
    /// (`app.slack.com/client/…`) detours through a browser tab first.
    private func deepLink(channel: String, message: String? = nil) -> String {
        var link = "slack://channel?team=\(teamID)&id=\(channel)"
        if let message { link += "&message=\(message)" }
        return link
    }

    // MARK: - Names

    private func dmName(channelID: String, isMPIM: Bool) async -> String {
        if isMPIM { return channelNames[channelID] ?? "group DM" }
        if let userID = imPartners[channelID] {
            return await displayName(userID: userID)
        }
        // A DM channel we hadn't enumerated (brand new conversation).
        if let api,
            let response = await api.tryCall("conversations.info", ["channel": channelID]) {
            let channel = response["channel"]
            if channel["is_mpim"].bool == true, let name = channel["name"].nonEmptyString {
                let pretty = prettyMPIMName(name)
                channelNames[channelID] = pretty
                return pretty
            }
            if let userID = channel["user"].nonEmptyString {
                imPartners[channelID] = userID
                return await displayName(userID: userID)
            }
        }
        return "someone"
    }

    private func displayName(userID: String) async -> String {
        if let cached = userNames[userID] { return cached }
        guard let api,
            let response = await api.tryCall("users.info", ["user": userID])
        else { return userID }
        let user = response["user"]
        let name =
            user["profile"]["display_name"].nonEmptyString
            ?? user["profile"]["real_name"].nonEmptyString
            ?? user["real_name"].nonEmptyString
            ?? user["name"].nonEmptyString
            ?? userID
        userNames[userID] = name
        return name
    }

    private func channelName(_ channelID: String) async -> String {
        if let cached = channelNames[channelID] { return cached }
        guard let api,
            let response = await api.tryCall("conversations.info", ["channel": channelID]),
            let name = response["channel"]["name"].nonEmptyString
        else { return channelID }
        channelNames[channelID] = name
        return name
    }

    /// `mpdm-brandon--alice--bob-1` → `alice, bob`.
    private func prettyMPIMName(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("mpdm-") { name.removeFirst("mpdm-".count) }
        if let dash = name.lastIndex(of: "-"),
            Int(name[name.index(after: dash)...]) != nil {
            name = String(name[name.startIndex..<dash])
        }
        let others = name.components(separatedBy: "--")
            .filter { !$0.isEmpty && $0 != selfUserName }
        return others.isEmpty ? "group DM" : others.joined(separator: ", ")
    }

    // MARK: - Text

    /// Turns Slack's markup into something readable in a one-line snippet:
    /// `<@U123>` → `@you`/`@name`, `<#C123|dev>` → `#dev`,
    /// `<https://x|label>` → `label`. Cache-only — never fires a lookup, since
    /// a chatty message would otherwise cost a `users.info` per mention.
    private func renderText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var out = ""
        var rest = Substring(raw)

        while let open = rest.firstIndex(of: "<") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: ">") else {
                out += rest[open...]
                rest = rest[rest.endIndex...]
                break
            }
            out += renderToken(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        out += rest

        let decoded = out
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    private func renderToken(_ token: String) -> String {
        let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
        let reference = parts.first ?? token
        let label = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil

        if reference.hasPrefix("@") {
            let id = String(reference.dropFirst())
            if id == selfUserID { return "@you" }
            return "@" + (label ?? userNames[id] ?? "someone")
        }
        if reference.hasPrefix("#") {
            let id = String(reference.dropFirst())
            return "#" + (label ?? channelNames[id] ?? "channel")
        }
        if reference.hasPrefix("!") {
            let keyword = String(reference.dropFirst())
            if keyword.hasPrefix("subteam^") { return "@" + (label ?? "team") }
            switch keyword {
            case "here", "channel", "everyone": return "@\(keyword)"
            default: return label ?? ""
            }
        }
        // Bare link: the label if there is one, else the URL itself.
        return label ?? reference
    }

    private static func truncate(_ text: String?, _ limit: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    /// Strips colons and any skin-tone suffix: `:+1::skin-tone-3:` → `+1`.
    private static func normalizeEmoji(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasPrefix(":") { name.removeFirst() }
        while name.hasSuffix(":") { name.removeLast() }
        if let separator = name.range(of: "::") {
            name = String(name[name.startIndex..<separator.lowerBound])
        }
        return name
    }

    // MARK: - Item references

    private enum RefKind {
        case dm
        case mention(ts: String)
        case save(ts: String)
    }

    private struct Reference {
        var kind: RefKind
        var channel: String
    }

    private struct StoredRef: Codable {
        var channel: String
        var ts: String
    }

    private static func payload(channel: String, ts: String) -> Data? {
        try? JSONEncoder().encode(StoredRef(channel: channel, ts: ts))
    }

    /// Recovers the channel/ts a triage verb needs. Prefers the item's stored
    /// payload and falls back to parsing the external id, so items written by
    /// an older build still complete.
    private static func reference(externalID: String, payload: Data?) -> Reference? {
        let stored = payload.flatMap { try? JSONDecoder().decode(StoredRef.self, from: $0) }
        // Channel ids are alphanumeric (no dashes) and a ts always contains a
        // dot, so splitting on "-" is unambiguous.
        let parts = externalID.split(separator: "-", maxSplits: 2).map(String.init)
        guard let prefix = parts.first else { return nil }
        let channel = stored?.channel ?? (parts.count > 1 ? parts[1] : nil)
        guard let channel, !channel.isEmpty else { return nil }
        let ts = parts.count > 2 ? parts[2] : stored?.ts

        switch prefix {
        case "dm":
            return Reference(kind: .dm, channel: channel)
        case "mention":
            guard let ts else { return nil }
            return Reference(kind: .mention(ts: ts), channel: channel)
        case "save":
            guard let ts else { return nil }
            return Reference(kind: .save(ts: ts), channel: channel)
        default:
            return nil
        }
    }

    private func requireAPI() throws -> SlackAPI {
        if let api { return api }
        // markDone can arrive before run() has connected; build on demand.
        guard let userToken = Keychain.get("\(sourceID).userToken"), !userToken.isEmpty else {
            throw SlackError(
                errorDescription:
                    "Slack: no user token (xoxp-…) configured for source \(sourceID).")
        }
        let api = SlackAPI(token: userToken)
        self.api = api
        return api
    }
}
