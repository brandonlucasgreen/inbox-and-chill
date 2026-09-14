# Buffer engagement as a source — what the API can do today (2026-09-14)

Brandon: *"Buffer just launched experimental access to an Engagement API,
which pulls in comments and mentions on one's social channels. This feels
like a perfect use case for a new notification source/type."*

Everything below was checked on 2026-09-14 against the **live public schema**
(introspected through Buffer's own MCP server, which fronts `api.buffer.com`),
the changelog, the reference, the roadmap, and one read-only
`configuration` query against Brandon's personal org. Rule 4 applies: the
verdict here supersedes the PLAN.md §6 row that said *"Buffer doesn't have a
notification webhook offering yet"* — that is still true, and there is now a
more specific reason.

## 1. The finding: the Engagement API is configuration, not data

The 2026-09-09 14:21 changelog entry adds ~90 schema members, and **every one
of them describes what a channel *supports*** — none returns a comment or a
mention. The whole surface is one query:

```graphql
configuration(input: { organizationId }) : Configuration
  channels: [ChannelConfiguration]     # per connected channel
    authorizationStatus: [{ feature: posting|comment|mention|insights|engagementReaction, status, reason }]
    engagement: [EngagementTypeConfiguration]
      engagementType: comment | mention
      syncData: { syncDataMechanism: polling | realTime, forcedSyncConfiguration: { pollInterval, forcedSyncRateLimit } }
      replying: { supportsReplying, prefixReplyWithMention }
      reactions: { supportedReactions: [like|love|celebrate|…] }
      supportedAiFeatures: [suggestions|insights]
```

What does **not** exist, checked three ways (schema text, reference page,
changelog): a `comments`/`mentions`/`engagements` query, a comment type with
text/author/timestamp, a reply or react mutation, a webhook or subscription.
`Query` has 16 fields and `Mutation` 13; none touch engagement data. The
reference page says the same in its own words: *"No direct queries or
mutations exist for comments, mentions, engagements, replies, or
reactions."* The roadmap's only related item is **"Community API"** —
*Exploring*, 16 votes, no date — and it lists nothing under webhooks or
real-time.

So: **a comments-and-mentions connector cannot be built against the public
API today.** This is the shape of a data API being announced ahead of its
data — the enums, the sync mechanism and the per-channel capability table
are exactly what the data queries will hang off. When they land, the
mapping in §4 is ready.

### What the probe against Brandon's org showed

Read-only `channels` + `configuration` for *Cult of Lightbulbs* (13
channels). Worth recording because it says what a connector will face:

| Fact | Value |
|---|---|
| Channels reporting `comment` engagement | 11 of 13 (all but Start Page and Pinterest) |
| Channels reporting `mention` | **1** — LinkedIn only |
| `syncDataMechanism: realTime` | Instagram ×2, Bluesky ×2, Threads ×2, Facebook, LinkedIn mentions |
| `syncDataMechanism: polling`, `pollInterval: 4` (units unstated; hours fits a `forcedSyncRateLimit` of 1 per 3600s) | Mastodon ×2, LinkedIn comments, YouTube (no forced-sync config) |
| `authorizationStatus` other than `ok` | both Mastodon channels: `notEnoughData` — *"The channel has no stored OAuth scopes. Required scopes: read, write."* |
| Every channel's `allowedActions` | includes `viewComments` and `manageComments` (except Start Page, Pinterest) |

Two things follow. **Mentions are nearly a LinkedIn-only feature** in this
API as it stands, so the source is really "comments on my posts" with
mentions as a bonus. And the `authorizationStatus` reason string is
already a rule-5 sentence — a connector should surface it verbatim rather
than translating a status enum.

## 2. Auth and limits — fits the house pattern, with one real constraint

- **Paste-a-token, as §6.9 requires.** Personal access token from
  publish.buffer.com › Settings › API, sent as `Authorization: Bearer …`,
  static (no expiry documented), **acts on behalf of the account across all
  its organizations** — no per-org scoping. OAuth (PKCE) exists but is the
  path §6.9 already rejected; nothing here changes that argument.
- **Rate limits are tight enough to decide the poll interval.** Per API key:
  100 per 15 min, **250 per 24 h** (Free and Essentials; Team 500), 3,000
  per 30 days (Free; Essentials 7,500; Team 15,000). The app's usual 60–120s
  poll is 720–1,440 calls a day — **three to six times the daily budget**.
  A Buffer connector needs `pollInterval` ≥ 900s (96/day, 2,880/30d — inside
  Free with almost no headroom, so one request per poll is a hard rule).
  429s come with `Retry-After` and code `RATE_LIMIT_EXCEEDED`; the
  `RateLimit` headers carry remaining/reset per window and are worth
  reading into the status line before the 429 arrives.
- **Complexity**: 175,000 points, depth 25 — irrelevant at one small query
  per poll.

## 3. What can be built now: comment-count deltas on sent posts

`Post.metrics` is public and stable and includes `comments` (plus
`reactions`, `reposts`, `shares`, …) with `metricsUpdatedAt`. A poll of
recent **sent** posts can turn *"comments went from 3 to 5 on this post"*
into a queue row — the same "done means seen, returns when `lastSeen`
moves" shape Sentry already uses.

```graphql
posts(first: 50, input: { organizationId, filter: { status: [sent], sentAt: { start: <now − 30d> } },
                          sort: [{ field: dueAt, direction: desc }] }) {
  edges { node { id text channel { name service externalLink } externalLink sentAt
                 metrics { type value } metricsUpdatedAt } }
  pageInfo { hasNextPage }
}
```

| | |
|---|---|
| Kind | `buffer`, one source per org (the token sees every org; the picker is also the token check, like Todoist's) |
| Item | one row per **post** with unseen comments: title *"3 new comments · @kidlightbulbs on Threads"*, snippet the post text, `occurredAt` = `metricsUpdatedAt` |
| External id | `post:<PostId>` — stable per post, so the row updates in place and `resurrectIfNeeded` revives it when the count rises after a dismiss (`occurredAt` moves with `metricsUpdatedAt`) |
| Capabilities | **none of `markDone`/`remoteTruth`** — there is no remote read-state, and a truncated 50-post window must not archive anything. Local done only, like ntfy. `providesContext` for the metric chips on `D`. |
| Group | `groupKey` = channel id, label `@name on Service` — one fold per channel, the same rule as Slack channels |
| Open | the post's `externalLink` (the live post on the network; a comment is answered there). `https`, already admitted by `AppState.openable` |
| Poll | 900s, one request; `snapshotWasComplete` irrelevant without `remoteTruth` |
| Cursor | last-seen count per post, in the connector's memory *and* persisted in the source's settings JSON, or every relaunch re-announces every commented post |

**What it is not:** it has no comment text, no author, no per-comment row,
no reply, and no mentions at all. It answers *"something happened on this
post, go look"*, which is the ntfy tier of usefulness rather than the Slack
tier. Brandon's call whether that clears the bar; the argument for it is
that it is the only Buffer signal available to anyone outside Buffer, and it
becomes the fallback path when the data API is rate-limited or a channel's
`authorizationStatus` is not `ok`.

**Two things to verify before writing it** (one curl each, no account
needed beyond his token): that `metrics` is populated for Threads, Bluesky
and Mastodon posts (the metrics API launched for the big networks first),
and how stale `metricsUpdatedAt` runs — if Buffer refreshes metrics hourly,
a 15-minute poll is already too eager and 3,600s is the honest interval.

## 4. The connector when the data queries ship — mapping decided in advance

Everything Buffer has already committed to in the enums maps onto this
app's model with no new machinery:

| Buffer | Inbox & Chill |
|---|---|
| `EngagementType.comment` | kind `buffer_comment`, low signal; **high** when the post is < 24h old (a fresh post's comments are the ones you answer) |
| `EngagementType.mention` | kind `buffer_mention`, **high** — a mention is someone addressing you, the Slack-mention analogue |
| per-channel `authorizationStatus != ok` | `ConnectorStatus.error` carrying `reason` verbatim, plus "Reconnect the channel in Buffer" |
| `syncDataMechanism` per channel | informational only — the app polls Buffer, Buffer polls the network; surface *"Buffer checks Mastodon every 4h"* as a chip so a quiet channel is not read as broken |
| `replying.supportsReplying` | **not a verb here.** Replying is composition, which this app does not do; `⏎` opens the comment on the network (or Buffer's Engage view if the payload carries one). A `reactions` write-back is the same call — leave it out until asked |
| read/seen state | `markDone` + `remoteTruth` **only if** the data API exposes a read/dismissed flag with a mutation. If it exposes only a list, the source is push-shaped like ntfy: local done, no archive-on-absence |
| Channel | `groupKey` channel id → one fold per channel; `Service` enum → the chip glyph |

Decisions that carry over from the rest of the tree, so they do not need
re-deciding: `occurredAt` is the comment's own timestamp (never `now`, §6.11);
`Store.update` refreshes `groupKey` but not `topicID`; Trello's lesson — the
token rides in a header and `send` rewraps `URLError` before
`String(describing:)` sees it; and the source editor gets **no** paragraph
on why it is a token (§6.9 copy budget).

## 5. Recommendation, in order

1. **Do not build the comments connector yet.** There is nothing to build
   against; the "experimental" label is on the capability table, not on
   data. Writing a connector to guessed field names is the failure
   `docs/source-candidates.md` §3 warns about, and here there is not even a
   spec to guess from.
2. **Ask inside Buffer what the data queries will look like and when.**
   Brandon is the one person here who can. The questions that change the
   connector: does the list carry a read/replied state (decides
   `remoteTruth`); is there a cursor or `since` argument (decides whether 96
   calls a day can keep up with `realTime` channels); will the daily rate
   limit be raised for engagement polling (it is sized for scheduling, not
   for an inbox).
3. **Build §3 now only if a "go look" row is worth having.** It is a
   ~250-line REST-shaped poller off `GitHubConnector`'s template, plus the
   org picker. Half a day, and it is the fallback path either way.
4. **When the data API lands, §4 is the spec.** Expect one connector file,
   two kinds, and the `TodoProjectPicker`-style org picker reused — no
   changes to `Store`, `SyncEngine` or `PanelQueue`.

## Sources

- Schema: introspection via Buffer MCP, 2026-09-14 (16 queries, 13 mutations)
- https://developers.buffer.com/changelog.html — 2026-09-09 14:21 entry
- https://developers.buffer.com/reference.html
- https://developers.buffer.com/roadmap.html — "Community API", Exploring
- https://developers.buffer.com/guides/authentication.html
- https://developers.buffer.com/guides/api-limits.html
- `configuration` + `channels` for org `645912daf924a7c53bf40cfc`, read-only
