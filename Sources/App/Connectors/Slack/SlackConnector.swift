import Foundation
import os

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
    nonisolated let capabilities: ConnectorCapabilities = [
        .markDone, .remoteTruth, .push, .providesContext,
    ]
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
    /// Channel id → message ts → keyword-watch hit (from Slack search).
    private var watchHits: [String: [String: RemoteItem]] = [:]
    /// `channel:ts` already emitted this process, so a re-poll over the same
    /// 24-hour window doesn't churn the store every five minutes.
    private var seenWatchHits: Set<String> = []
    /// Set when Slack rejects the search in a way retrying can't fix.
    private var searchDisabled = false
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

    /// How often the keyword watch polls Slack search.
    private static let searchInterval: Duration = .seconds(300)
    /// How far back one poll looks. Re-finding the same message is harmless
    /// (see `searchLoop`), so this only needs to comfortably exceed the poll
    /// interval and survive the app being closed for a while.
    private static let searchWindow: TimeInterval = 24 * 60 * 60
    /// Bounds the cost of a poll: it is one `search.messages` call per term.
    /// Non-private so `parseSearchTerms` in the SlackSearch extension can see it.
    static let maxSearchTerms = 10
    /// Matches requested per term. Slack sorts newest-first, so a term noisier
    /// than this loses only the oldest hits in the window.
    private static let searchCount = 20
    /// Matches requested per term when channels are muted. Muted hits are
    /// dropped *after* Slack has ranked them, so a chatty muted channel would
    /// otherwise spend the whole page on messages you asked not to see and
    /// push real hits out of the window. Asking for more restores the yield.
    private static let mutedSearchCount = 60

    /// Terms to watch for across the workspace, from settings.
    private let searchTerms: [String]
    /// Channels whose messages never become items, from settings. Names are
    /// lowercased and `#`-stripped; a raw channel id is kept as-is.
    private let mutedChannels: Set<String>

    init(
        sourceID: String = "slack", saveEmoji: String = "pushpin", searchTerms: String = "",
        mutedChannels: String = ""
    ) {
        self.sourceID = sourceID
        let normalised = Self.normalizeEmoji(saveEmoji)
        self.saveEmoji = normalised.isEmpty ? "pushpin" : normalised
        self.searchTerms = Self.parseSearchTerms(searchTerms)
        self.mutedChannels = Self.parseMutedChannels(mutedChannels)
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
            + watchHits.values.flatMap { $0.values }
        return all.sorted { $0.occurredAt > $1.occurredAt }
    }

    func markDone(externalID: String, payload: Data?) async throws {
        guard let ref = Self.reference(externalID: externalID, payload: payload) else {
            throw SlackError(
                errorDescription: "Slack: don't know how to complete \(externalID).")
        }

        // A keyword hit can live in a channel you're not a member of, where
        // `conversations.mark` would fail — and where there is no read state
        // to move in the first place. Clearing it locally *is* the verb, so it
        // resolves before we even require a token.
        if case .watch(let ts) = ref.kind {
            watchHits[ref.channel]?.removeValue(forKey: ts)
            return
        }

        let api = try requireAPI()
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

        case .watch:
            break  // Cleared above; it needs no Slack call.
        }
    }

    // MARK: - Run loop

    func run(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {
        emit(.status(.connecting))
        do {
            let appToken = try await connect()

            try await withThrowingTaskGroup(of: Void.self) { group in
                // The keyword watch is pure Web API — it needs nothing that
                // seeding, the socket, or the app-level token provide. It runs
                // as a sibling of all of that, deliberately: `seed()` walks
                // every conversation in the workspace, which on a large one
                // takes minutes, and hanging the watch behind it meant it
                // never ran at all.
                //
                // Only added when there is something to watch for. An empty
                // search would return immediately, and in a task group the
                // first child to finish tears down the run — so an unused
                // keyword watch would restart the whole connector every 5s.
                if !searchTerms.isEmpty {
                    group.addTask { [self] in await self.searchLoop(emit: emit) }
                }

                group.addTask { [self] in
                    try await self.seed(emit: emit)

                    guard let appToken else {
                        // User token only. Channel mentions are unavailable —
                        // Slack has no polling API for them (see `seed`) — but
                        // DM unreads, emoji saves and read-state auto-clear are
                        // all pollable, so the source still works.
                        emit(.status(.ok(.now)))
                        try await self.pollOnlyLoop(emit: emit)
                        return
                    }

                    let socket = try await SlackSocket.open(appToken: appToken)
                    defer { socket.close() }
                    emit(.status(.ok(.now)))

                    // The socket reader and the read-state safety net;
                    // whichever finishes first ends this branch.
                    try await withThrowingTaskGroup(of: Void.self) { inner in
                        inner.addTask { [self] in
                            try await self.readLoop(socket: socket, emit: emit)
                        }
                        inner.addTask { [self] in
                            await self.readStateLoop(emit: emit)
                        }
                        _ = try await inner.next()
                        inner.cancelAll()
                    }
                }

                // Whichever child finishes first ends this run; the SyncEngine
                // restarts us after 5s.
                _ = try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            // A connector that dies here restarts every 5s forever. Without
            // this line that loop is completely silent — the failure only
            // ever reached the status dot.
            Self.searchLog.error(
                "slack run() failed: \(String(describing: error), privacy: .public)")
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

    // MARK: - Keyword watch

    /// Polls Slack search for the configured terms.
    ///
    /// This is the only path that can see a message in a **public channel you
    /// are not a member of** — `message.channels` is delivered for your
    /// memberships only, so events structurally cannot carry it, and Slack
    /// itself won't notify you either. Search is workspace-wide, so it closes
    /// that blind spot and generalises to arbitrary keywords at the same time.
    ///
    /// Deliberately non-throwing, like `readStateLoop`: a search hiccup (an
    /// expired scope, a rate limit) must not tear down the socket and take
    /// DMs and mentions with it.
    ///
    /// Re-finding a message is safe by construction. A hit's `occurredAt` is
    /// the message timestamp, which is always older than the moment you
    /// dismissed it, so `Store.resurrectIfNeeded` leaves a done item done —
    /// `seenWatchHits` is an efficiency measure, not a correctness one.
    private static let searchLog = Logger(
        subsystem: "lol.bgreen.inboxandchill", category: "keyword-watch")

    /// The seed had no logging at all until 2026-08-23, which is how "I
    /// pasted the token and nothing happened" became unanswerable: the save
    /// re-seed sits at the end of a multi-minute conversation walk, and
    /// `tryCall` swallowed whatever `reactions.list` said. Every stage of
    /// the seed now says where it got to.
    private static let seedLog = Logger(
        subsystem: "lol.bgreen.inboxandchill", category: "slack-seed")

    private func searchLoop(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {
        Self.searchLog.info(
            "keyword watch started, terms=\(self.searchTerms.count, privacy: .public)")
        // Never returns of its own accord: this runs as a task-group child, and
        // a child that finishes cancels its siblings. When the watch is
        // disabled by a permanent Slack rejection it parks here rather than
        // completing, so the rest of the connector keeps running.
        while !Task.isCancelled {
            if !searchDisabled { await runSearch(emit: emit) }
            do { try await Task.sleep(for: Self.searchInterval) } catch { return }
        }
    }

    private func runSearch(emit: @escaping @Sendable (ConnectorEvent) -> Void) async {
        guard let api, !searchTerms.isEmpty else {
            Self.searchLog.error("runSearch bailed: api=\(self.api != nil, privacy: .public)")
            return
        }
        let cutoff = Date().addingTimeInterval(-Self.searchWindow)

        var fresh: [RemoteItem] = []
        for term in searchTerms {
            guard !Task.isCancelled else { return }
            let query = Self.searchQuery(term: term, after: cutoff)
            let response: SlackJSON
            do {
                response = try await api.call(
                    "search.messages",
                    [
                        "query": query,
                        "count": String(
                            mutedChannels.isEmpty ? Self.searchCount : Self.mutedSearchCount),
                        "sort": "timestamp", "sort_dir": "desc",
                    ])
            } catch let error as SlackError
                where Self.permanentSearchFailures.contains(error.slackCode ?? "")
            {
                // Not transient, and silence here would look identical to
                // "nothing matched" forever. Say what's wrong and stop.
                searchDisabled = true
                emit(.status(.error(Self.searchScopeAdvice(code: error.slackCode ?? ""))))
                return
            } catch {
                continue  // Transient (rate limit, network): try the next tick.
            }

            let matches = response["messages"]["matches"].array ?? []
            Self.searchLog.info(
                "term=\(term, privacy: .public) matches=\(matches.count, privacy: .public)")
            for match in matches {
                guard
                    let hit = Self.watchHit(
                        from: match, term: term, selfUserID: selfUserID,
                        teamID: teamID, notBefore: cutoff)
                else { continue }
                // Muting wins over watching: the whole point is "this term,
                // everywhere except here".
                if Self.isMuted(
                    channelName: match["channel"]["name"].nonEmptyString,
                    channelID: hit.channel, muted: mutedChannels)
                {
                    continue
                }
                let key = "\(hit.channel):\(hit.ts)"
                guard !seenWatchHits.contains(key) else { continue }
                // A channel you're in already produces a real mention item via
                // events; don't shadow it with a search copy.
                guard mentions[hit.channel]?[hit.ts] == nil else { continue }
                seenWatchHits.insert(key)
                var item = hit.item
                // `watchHit` is static so it can be tested without a socket,
                // which also means it can't reach the name caches — it leaves
                // the raw text, `<@U056HVBKTSA>` and all. Rendering has to
                // happen here, where the ids can actually be looked up.
                if let raw = match["text"].nonEmptyString {
                    await resolveReferences(in: raw)
                    item.snippet = Self.truncate(
                        renderText(raw), Self.snippetLimit) ?? item.snippet
                }
                watchHits[hit.channel, default: [:]][hit.ts] = item
                fresh.append(item)
            }
        }
        Self.searchLog.info("queueing \(fresh.count, privacy: .public) keyword hits")
        if !fresh.isEmpty { emit(.upsert(fresh)) }
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
        let startedAt = ContinuousClock.now
        Self.seedLog.info("seed started")

        // Saves are seeded FIRST, before the conversation walk, and that
        // ordering is the whole point rather than a tidy-up.
        //
        // Measured 2026-08-23 on a real workspace: `listConversations`
        // returned **377** DM refs, and `unreadStates` then spends one
        // `conversations.info` on each at five concurrent, against a Slack
        // tier that allows ~50 a minute. So the DM walk takes the better
        // part of ten minutes, and every 429 it earns sleeps for the
        // `Retry-After` on top. `seedEmojiSaves` used to sit *after* all of
        // that — one cheap call stuck behind several hundred expensive ones.
        //
        // Which made it effectively unreachable, because a re-register
        // starts `seed()` over from zero: saving the source in Settings to
        // "make it pick up my saves" restarted the walk instead, so the more
        // times you asked, the further away the answer got. This is the same
        // trap CLAUDE.md already records for the keyword watch — independent
        // work must not be downstream of `seed()` — and saves were the
        // second instance of it.
        //
        // It costs the DM seed one round trip, plus a `conversations.info`
        // per distinct channel a save lives in (the name cache is empty this
        // early). Against 377, that is noise.
        await seedEmojiSaves(api: api, emit: emit)

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

        Self.seedLog.info(
            """
            conversations walked in \
            \(startedAt.duration(to: .now).components.seconds, privacy: .public)s, \
            dms=\(dmRefs.count, privacy: .public)
            """)

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
        Self.seedLog.info(
            """
            dm state done in \
            \(startedAt.duration(to: .now).components.seconds, privacy: .public)s, \
            unread=\(upserts.count, privacy: .public)
            """)

        Self.seedLog.info(
            "seed finished in \(startedAt.duration(to: .now).components.seconds, privacy: .public)s")
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
    /// was closed still land in the queue — and, since 2026-08-23, so that a
    /// change to an item's *shape* reaches rows that already exist.
    ///
    /// It needs `reactions:read`. It used to need it silently: `tryCall`
    /// swallows the error, so a missing scope, a revoked token and an empty
    /// account were one indistinguishable no-op. That is the rule-5 failure
    /// this app exists to prevent, and it is exactly what made "I pasted the
    /// token and nothing happened" impossible to answer. Permanent failures
    /// now name themselves in Settings; transient ones log and move on.
    private func seedEmojiSaves(
        api: SlackAPI, emit: @escaping @Sendable (ConnectorEvent) -> Void
    ) async {
        var cursor: String?
        var items: [RemoteItem] = []
        var scanned = 0
        for page in 0..<Self.savePageBudget {
            var params = [
                "user": selfUserID, "limit": String(Self.savePageSize),
                "full": "true",
            ]
            if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
            let response: SlackJSON
            do {
                response = try await api.call("reactions.list", params)
            } catch {
                let code = (error as? SlackError)?.slackCode ?? ""
                Self.seedLog.error(
                    """
                    reactions.list failed on page \(page, privacy: .public): \
                    code=\(code, privacy: .public) \
                    keeping \(items.count, privacy: .public) already read — \
                    \(error.localizedDescription, privacy: .public)
                    """)
                if Self.permanentSearchFailures.contains(code) {
                    emit(.status(.error(Self.savedScopeAdvice(code: code))))
                }
                // `break`, not `return`. This used to bail with a bare
                // `return`, which threw away every save read from every
                // earlier page — and that is what made saves look
                // permanently broken rather than occasionally short.
                //
                // Observed 2026-08-23: page 0 succeeded, page 1 came back
                // `internal_error` (Slack's own transient fault, nothing to
                // do with scopes), and a hundred saves went in the bin on
                // every single connect. Emitting a short list is right here
                // because saves are only ever `.upsert`ed — this connector
                // deliberately never emits `.snapshot`, so a partial read
                // can never be mistaken for "the rest were handled
                // remotely" and cannot archive anything.
                break
            }

            for entry in response["items"].array ?? [] {
                scanned += 1
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
                let item = await makeSaveItem(
                    channel: channel, ts: ts, text: message["text"].string,
                    author: message["user"].nonEmptyString,
                    permalink: permalink)
                saves[item.externalID] = item
                items.append(item)
            }

            cursor = response["response_metadata"]["next_cursor"].nonEmptyString
            if cursor == nil { break }
        }
        // `scanned` vs `items` is the distinction that matters when a user
        // says saves aren't arriving: a big `scanned` with zero `items` means
        // the save emoji doesn't match what they actually reacted with, which
        // is a different problem from a rejected call or an empty account.
        Self.seedLog.info(
            """
            reactions.list scanned=\(scanned, privacy: .public) \
            saves=\(items.count, privacy: .public) \
            emoji=\(self.saveEmoji, privacy: .public)
            """)

        if !items.isEmpty { emit(.upsert(items)) }
    }

    /// **`reactions.list` stops dead after 100 items, whatever you ask for.**
    ///
    /// Measured against a real workspace, 2026-08-23. At `limit=100` Slack
    /// served page 0 and failed page 1 with `internal_error`; at `limit=25`
    /// it served pages 0–3 and failed page 4. Both had scanned **exactly
    /// 100 reactions** when they died, so the wall is an offset, not a
    /// response size, and paging more finely just buys more round trips to
    /// reach the same place. `internal_error` is Slack's own fault code and
    /// says nothing about scopes or the token — which is precisely why this
    /// needed measuring rather than reasoning about.
    ///
    /// The consequence is worth being straight about: **the backfill can
    /// only ever see your 100 most recent reactions.** A save older than
    /// that is unreachable, and no amount of reconnecting will find it —
    /// re-applying the emoji is the only way, because that fires
    /// `reaction_added` and takes the live path instead.
    ///
    /// So `limit` stays at 100: the fewest calls to reach the only 100
    /// items obtainable. The page budget is what it always was, and now
    /// `break`s with its partial list rather than discarding it.
    private static let savePageSize = 100
    private static let savePageBudget = 5

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
        // A muted channel is muted for real mentions too, not just keyword
        // hits — otherwise "mute #random" would still deliver the noisiest
        // thing #random can produce. The name lookup is cached: seed() warms
        // it for every channel you're a member of, which is every channel an
        // event can arrive from.
        if !mutedChannels.isEmpty,
            Self.isMuted(
                channelName: await channelName(channel), channelID: channel,
                muted: mutedChannels)
        {
            return
        }
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
        var author: String?
        if let history = await api.tryCall(
            "conversations.history",
            [
                "channel": channel, "latest": ts, "oldest": ts,
                "inclusive": "true", "limit": "1",
            ]) {
            text = history["messages"][0]["text"].string
            author = history["messages"][0]["user"].nonEmptyString
        }

        let item = await makeSaveItem(
            channel: channel, ts: ts, text: text, author: author,
            permalink: permalink)
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
            snippet: Self.truncate(renderText(text), Self.snippetLimit),
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
            snippet: Self.truncate(renderText(text), Self.snippetLimit),
            url: deepLink(channel: channel, message: ts),
            actorName: who,
            occurredAt: SlackTS.date(ts) ?? .now,
            highSignal: true,
            payload: Self.payload(channel: channel, ts: ts))
    }

    /// A saved message.
    ///
    /// Until 2026-08-23 this put the *message* in the title, cut to 80
    /// characters, and left `snippet` nil — so a saved message had no body
    /// at all, D had nothing to reveal, and the 80 characters were gone
    /// before the store ever saw them. The text now goes where every other
    /// kind puts it, and the title says what the row *is*.
    private func makeSaveItem(
        channel: String, ts: String, text: String?, author: String?,
        permalink: String?
    ) async -> RemoteItem {
        // Ids are resolved before rendering here and not for DMs or
        // mentions, because this is the body D opens: an unresolved
        // `<@U056HVBKTSA>` two paragraphs in is the reason to have bothered.
        if let text { await resolveReferences(in: text) }
        var who: String?
        if let author { who = await displayName(userID: author) }
        return RemoteItem(
            externalID: "save-\(channel)-\(ts)",
            kind: "emoji_save",
            title: Self.saveTitle(
                channelLabel: await channelName(channel)),
            snippet: Self.truncate(renderText(text), Self.snippetLimit),
            // Prefer a native deep link built from the permalink; the
            // permalink itself rides along in the payload as the fallback
            // for a Mac with no Slack app (see `AppState.open`).
            url: permalink.flatMap {
                Self.nativeLink(fromPermalink: $0, teamID: teamID)
            } ?? permalink ?? deepLink(channel: channel, message: ts),
            actorName: who,
            occurredAt: SlackTS.date(ts) ?? .now,
            highSignal: false,
            payload: Self.payload(channel: channel, ts: ts, permalink: permalink))
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

    /// Warms the name caches for every id a message refers to, so
    /// `renderText` can turn `<@U056…>` into `@bruno` rather than the
    /// nothing-word "@someone".
    ///
    /// One `users.info` per id never seen before, then cached for the
    /// connector's life. Labelled references (`<@U056…|bruno>`) carry their
    /// own name and cost no call at all.
    private func resolveReferences(in raw: String) async {
        let references = Self.unlabelledReferences(in: raw)
        for id in references.users where userNames[id] == nil {
            _ = await displayName(userID: id)
        }
        for id in references.channels where channelNames[id] == nil {
            _ = await channelName(id)
        }
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

    // MARK: - Item references

    private enum RefKind {
        case dm
        case mention(ts: String)
        case save(ts: String)
        case watch(ts: String)
    }

    private struct Reference {
        var kind: RefKind
        var channel: String
    }

    private struct StoredRef: Codable {
        var channel: String
        var ts: String
        /// The https permalink, kept so a row whose link is `slack://` can
        /// still fall back to the web when Slack isn't installed — and so
        /// the shareable form of the link is never thrown away.
        var permalink: String?
    }

    /// Rewrites a Slack permalink as a native deep link.
    ///
    /// Slack.app registers the `slack` URL scheme and **nothing else**: it
    /// declares no associated domains, so an `https://…slack.com/archives/…`
    /// URL cannot be handed to it directly. Opening one goes to the default
    /// https handler — a browser, or a picker like Velja — which loads a page
    /// whose only job is to bounce back into Slack. This skips all of that.
    ///
    /// Permalinks look like
    /// `https://<workspace>.slack.com/archives/<CHANNEL>/p<ts without its dot>`,
    /// optionally with `?thread_ts=…&cid=…`. Returns nil for anything that
    /// isn't that shape, so an unfamiliar link is left alone rather than
    /// turned into a deep link that goes nowhere.
    nonisolated static func nativeLink(
        fromPermalink permalink: String, teamID: String
    ) -> String? {
        guard !teamID.isEmpty,
            let url = URL(string: permalink),
            url.host()?.hasSuffix("slack.com") == true
        else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts[0] == "archives" else { return nil }
        let channel = parts[1]
        // `p1786640860239779` → `1786640860.239779`: the dot always sits six
        // digits from the end.
        let stamp = parts[2]
        guard stamp.hasPrefix("p") else { return nil }
        let digits = stamp.dropFirst()
        guard digits.count > 6, digits.allSatisfy(\.isNumber) else { return nil }
        let ts = "\(digits.dropLast(6)).\(digits.suffix(6))"

        var link = "slack://channel?team=\(teamID)&id=\(channel)&message=\(ts)"
        // A permalink to a threaded reply carries the parent's ts; without it
        // Slack opens the channel rather than the thread.
        if let thread = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "thread_ts" })?.value,
            !thread.isEmpty
        {
            link += "&thread_ts=\(thread)"
        }
        return link
    }

    /// The https permalink stored alongside a Slack item, if it has one.
    /// `AppState.open` uses it when nothing on this Mac handles `slack://`.
    nonisolated static func permalink(in payload: Data) -> String? {
        let stored = try? JSONDecoder().decode(StoredRef.self, from: payload)
        guard let permalink = stored?.permalink, !permalink.isEmpty else {
            return nil
        }
        return permalink
    }

    /// Non-private so `watchHit` in the SlackSearch extension can call it.
    static func payload(
        channel: String, ts: String, permalink: String? = nil
    ) -> Data? {
        try? JSONEncoder().encode(
            StoredRef(channel: channel, ts: ts, permalink: permalink))
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
        case "watch":
            guard let ts else { return nil }
            return Reference(kind: .watch(ts: ts), channel: channel)
        default:
            return nil
        }
    }

    // MARK: - Context (D expansion)

    /// The conversation around a mention, keyword hit or emoji save — the
    /// feature request verbatim: "the 3-5 messages preceding it and after it
    /// in the thread, so I can see the context in which I was mentioned".
    ///
    /// Thread first: `conversations.replies` accepts the ts of *any* message
    /// in a thread and returns the whole thread, so one call covers both a
    /// mention that is a reply and one that started the thread. A message in
    /// no thread errors (`thread_not_found`), and the fallback is a window of
    /// the channel itself around the ts. Both are covered by the history
    /// scopes the manifest has always requested — no reinstall.
    ///
    /// DM rows get nothing: they represent a *conversation's* unread state,
    /// not one message, so there is no anchor to fan out from.
    func context(externalID: String, payload: Data?) async throws -> ItemContext? {
        guard let ref = Self.reference(externalID: externalID, payload: payload)
        else { return nil }
        let focusTS: String
        switch ref.kind {
        case .dm: return nil
        case .mention(let ts), .save(let ts), .watch(let ts): focusTS = ts
        }
        let api = try requireAPI()

        var raw: [ContextRaw] = []
        var isThread = false
        if let replies = await api.tryCall("conversations.replies", [
            "channel": ref.channel, "ts": focusTS, "limit": "200",
        ]) {
            raw = Self.rawMessages(replies["messages"])
            // `ts` of a *reply* answers with just that one message, not its
            // thread (verified against Brandon's workspace 2026-08-23 — a
            // reply-mention was falling through to the channel window). The
            // parent is the message's own thread_ts; ask again with that and
            // the whole thread comes back.
            if raw.count == 1, let parent = raw.first?.threadTS,
                parent != focusTS,
                let thread = await api.tryCall("conversations.replies", [
                    "channel": ref.channel, "ts": parent, "limit": "200",
                ])
            {
                raw = Self.rawMessages(thread["messages"])
            }
            isThread = raw.count > 1
        }
        if !isThread {
            // Not a thread: window the channel. `latest` + inclusive gives
            // the message and up to 3 before; the after-side fetches a page
            // and lets `window` pick the 3 *closest* rather than trusting
            // the API's sort, which differs by parameter combination.
            let before = try await api.call("conversations.history", [
                "channel": ref.channel, "latest": focusTS,
                "inclusive": "true", "limit": "4",
            ])
            let after = await api.tryCall("conversations.history", [
                "channel": ref.channel, "oldest": focusTS,
                "inclusive": "false", "limit": "100",
            ])
            raw = Self.rawMessages(before["messages"])
                + Self.rawMessages(after?["messages"] ?? .null)
        }

        guard let window = Self.window(raw, focusTS: focusTS, radius: 3)
        else { return nil }

        var messages: [ItemContext.Message] = []
        for (index, message) in window.messages.enumerated() {
            let isFocus = index == window.focusIndex
            await resolveReferences(in: message.text)
            let author: String
            if let user = message.user {
                author = await displayName(userID: user)
            } else {
                author = "app"
            }
            let text = renderText(message.text) ?? message.text
            messages.append(.init(
                author: author,
                // The focus is the row's body replacement — the whole point
                // of D — so it keeps the same generous cap as the snippet.
                text: String(text.prefix(isFocus ? Self.snippetLimit : 300)),
                isFocus: isFocus))
        }

        var label = isThread ? "Thread" : "Around this message"
        if let name = channelNames[ref.channel] { label += " · #\(name)" }
        var context = ItemContext(messages: messages, replacesBody: true)
        context.messagesLabel = label
        return context
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
