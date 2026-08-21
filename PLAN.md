# Inbox & Chill — Plan

*A native macOS menu bar app that aggregates your unread/actionable queue across Slack, Linear, GitHub, ntfy, terminal apps (incl. Claude Code), and custom sources.*

> Status: v3 — BUILT (2026-08-17). All milestones implemented; 33 tests green. Remaining human steps: Slack app install approval, Campsite Doorkeeper token, per-source API keys, Developer ID signing for release. See README.md and docs/.

## 1. The problem

To-dos and "things awaiting me" live in at least seven places: Linear inbox, Slack mentions/unreads, Notion mentions/comments, Campsite notifications, GitHub review requests/mentions, Apple Reminders, plus ad-hoc internal tools. Checking each app daily is a tax; not checking means dropped balls. The goal is a single, fast, native menu bar surface — inspired by the Reminders MenuBar app — where every service is just another *vector* feeding one queue.

## 2. What this app is (and isn't)

- **Is**: a **triage queue** (inbox-zero machine), not a status mirror. Items flow in; the job is to empty the list. Local done-state is the universal layer; where a service supports mark-read (Linear, GitHub, Slack, Campsite) we write through so the two never drift.
- **Is not**: a full client for any service. No composing Slack messages, no editing Linear issues. The moment an item needs real work, we deep-link into the owning app.
- **Is not**: a web app in a window. Native Swift, SwiftUI-first, AppKit where needed.

### 2.1 Locked product decisions (grill-me, 2026-08-17)

1. **Triage queue** with write-through where supported.
2. **Hybrid open/done**: items whose source clears them naturally (Slack unreads via Slack's own read-state) auto-clear; everything else dies only by explicit done (E).
3. **Badge**: Settings choice of total count / high-signal count / dot / none (default: high-signal), with per-source "counts toward badge" toggles. Zero = clean icon.
4. **App notifications**: silent by default; per-source opt-in banners; Claude/terminal sources default on; Focus modes respected.
5. **Snooze**: write-through for Linear (real remote snooze), local for the rest, identical UI; snoozed items visible in a collapsed section; a waking item always banners (snoozing is consent to be interrupted). *Amendment: under a Focus mode, wake banners defer like any notification — honoring "always" literally would require the time-sensitive entitlement; politeness wins.*
6. **Done items archive for 90 days** (searchable, ⌘Z undo-done), then purge. **Pin (⌘P)** exempts an item from *all* auto-clears, done, and purge — pinned section at top of panel, leaves only by unpinning.
7. **Distribution**: personal-first, built for eventual GitHub release ("I very much want to share this"); Developer ID + notarization, **no App Sandbox** (it fights the terminal/CLI features); App Store **audited and declined 2026-08-20 — see §2.1.8**. Shared users bring their own Slack app via a bundled manifest (keeps everyone in Slack's internal-app rate-limit tier) and their own PATs/keys.
8. **Cloudflare relay deferred; Notion connector demoted to build-on-demand** (Notion's tenure in the stack is itself uncertain). v1 is fully self-contained — zero infrastructure.
9. **Slack save emoji**: configurable, default 📌 `:pushpin:`. Slack app created + install attempted immediately.
10. **Naming**: app **Inbox & Chill**, CLI **`inchill`**, bundle ID **`lol.bgreen.inboxandchill`**.
11. **Panel defaults**: All view grouped by source with sticky headers; global hotkey customizable, default **⌥⌘I**.
12. **macOS 15 (Sequoia) minimum**; dev machine is 26 (Tahoe). Gate any future 26-only API per-feature, not app-wide.
13. Apple Reminders connector deprioritized (RemindersMenubar already serves it).

## 3. Mac app classification (per the Mac-arsed workflow)

**Shape**: utility / menu bar app, backed by a lightweight shoebox (a local store of notification items). Closest kin: Reminders MenuBar, Fantastical's menu bar mode, CodeEdit's… no — closest kin is actually **GitHub's old Trailer app** and **Mailplane-style unified badge counts**, but done as a first-class 2026 SwiftUI app.

**Core objects**:
### 2.1.8 Mac App Store — audited 2026-08-20, declined

Brandon asked whether MAS was viable. It was tested, not reasoned about: a
sandboxed variant was built (`CODE_SIGN_ENTITLEMENTS` override, `app-sandbox` +
`network.client`/`network.server` + `automation.apple-events` +
`files.user-selected.read-write`), launched, and observed.

**What works.** The app builds, launches and keeps its localhost architecture:
`NWListener` binds fine under `com.apple.security.network.server`. The embedded
`inchill` is *not* sandboxed, so Claude Code can still execute it.

**What breaks, all verified:**

1. **The `inchill` handshake.** `URL.applicationSupportDirectory` redirects into
   the container — `local-api.json` was written to
   `~/Library/Containers/lol.bgreen.inboxandchill/Data/…` while the CLI reads
   `~/Library/Application Support/…`. Every hook fails. *Fixable*: same-user
   containers are `drwx------` and readable, so the CLI can try the container
   path first.
2. **`~/.claude/settings.json`.** Outside the container: needs a folder picker
   plus a persisted security-scoped bookmark, on a hidden directory, and the
   *folder* rather than the file because backups are written beside it. The
   one-click integration becomes a picker dance.
3. **The journal.** `{{YYYY}}` tokens resolve to a different file daily, so a
   file bookmark cannot work — it needs a folder bookmark. (The Obsidian
   iCloud vault was denied even *un*sandboxed, confirming the existing Full
   Disk Access requirement.)

**Policy risk that cannot be tested locally:** Apple Mail and the terminal-tab
focus both need `com.apple.security.automation.apple-events`, which MAS
permits — but "reads your mail" and "sends Apple events to arbitrary
terminals" draw review scrutiny, and guideline 2.4.5(i) is precisely about not
writing outside your container, which the Claude Code integration does by
design.

**Also required, and absent:** MAS needs an App ID, an embedded provisioning
profile and an Apple Distribution certificate. He holds Developer ID and Apple
Development only. And a sandboxed app gets a container-scoped keychain, so
every token would need re-pasting.

**Verdict — declined.** Technically buildable only as a degraded fork, and the
Claude Code integration is the most exposed feature. Developer ID +
notarization already works and costs no review latency. **Do not re-open this
without new information**; the reasoning is the evidence above, not a
preference. His call, given the audit: skip MAS, spend the effort on the
GitHub release path instead.

### 2.1.9 In-app updates via Sparkle — built 2026-08-21, dormant until the repo is public

Sparkle 2.9.6 is wired in, signed, and verified end to end. It is **inert
until the repository is public**, and that is a constraint of the mechanism,
not a missing feature.

**Why public is not negotiable.** Sparkle fetches two things with no
credentials: `appcast.xml` and the zip the feed names. A private repo's release
assets return 404 to everyone but a collaborator, so there is nothing for it to
read. Sparkle *does* expose an `httpHeaders` property, so "it cannot send a
token" would be wrong — but any token shipped inside a distributed app is
public by construction, and this one would grant repo read access to anyone who
ran `strings` on the binary. So the honest statement is: **a credential cannot
be kept secret in a downloadable app, therefore the feed and the download must
be things anyone may fetch.**

**The consequence for selling a build, decided 2026-08-21.** A public
auto-update feed and a paywalled binary are mutually exclusive. The feed must
name a URL that anybody can download, and the feed URL itself is readable out
of the shipped app. With license-key gating ruled out as a non-goal, there is
no way to serve updates to buyers only. Brandon's call: **the purchase is
support and convenience — skipping the build step and funding the work — not
access.** The README has to say that plainly rather than implying the paid
build is the only signed one, because it isn't.

**What was verified rather than assumed:**

- The whole appcast pipeline, against the real notarized zips: signing,
  `sparkle:minimumSystemVersion` extraction from `LSMinimumSystemVersion`,
  per-release download URLs, and an EdDSA signature checked back with
  `sign_update --verify`.
- That `generate_appcast` signs an enclosure **only when the app inside the
  archive declares `SUPublicEDKey`**. A build made before the key existed
  produces a silently unsigned entry, which Sparkle then refuses. `appcast.sh`
  fails loudly on that rather than publishing it.
- That Xcode leaves Sparkle's four nested helpers ad-hoc signed. See CLAUDE.md;
  it is the notarization trap of this change.

**Still Brandon's to do:** create the signing key (`scripts/sparkle-keys.sh`),
flip the repo public, and — if he still wants the paid path — create the Lemon
Squeezy product. None is scriptable.

- **Item** — one actionable notification (a Slack mention, a Linear inbox entry, a PR review request, a Claude-waiting event). Can be: opened (deep link), selected, copied (URL + title), marked done (with write-through + ⌘Z undo), snoozed, **pinned**, archived, filtered, grouped.
- **Source** — a configured connection (Slack workspace, Linear org, GitHub account, webhook endpoint). Can be: added, paused, removed, reordered, badge-toggled.

## 4. Architecture

### 4.1 Substrate

- **Swift 6, SwiftUI-first**, macOS 15+ (Sequoia) minimum — lets us use modern `MenuBarExtra` improvements, Swift Testing, and strict concurrency.
- **`MenuBarExtra` with `.menuBarExtraStyle(.window)`** for the popover-style panel (rich, interactive content — the Reminders MenuBar pattern). A plain NSMenu can't host the list UI we want.
- **AppKit bridges only where SwiftUI blocks us** (likely: precise status-item icon badging via `NSStatusItem`, global keyboard shortcut registration, maybe `NSVisualEffectView` for the panel material).
- **No Electron, no Catalyst.** Performance and delight are stated requirements.

### 4.2 Process model

Single app process. Per-source **connectors** are actor-isolated Swift types conforming to a common protocol:

```swift
protocol Connector: Actor {
    var source: Source { get }
    func fetch() async throws -> [Item]          // pull latest queue
    func markRead(_ item: Item) async throws      // where supported
    var capabilities: ConnectorCapabilities { get } // canMarkRead, canSnoozeRemotely, supportsPush…
}
```

A central **SyncEngine** (actor) schedules fetches per-connector with per-source cadence and jittered backoff, merges results into the store, and diffs to decide badge updates / local notifications. Connectors that support push (webhooks via a relay, Reminders via EventKit change notifications) update reactively instead of polling.

### 4.3 Storage

- **SwiftData** (or GRDB if we hit SwiftData limits) for the item store: item id, source, type, title, snippet, deep-link URL, actors, timestamps, readAt, snoozedUntil, local state.
- Store is a *cache with local annotations* — the services remain the source of truth for read state where they support it; local-only state (snooze, "done locally") layers on top.
- **Keychain** for every token/secret. Nothing sensitive in UserDefaults or on disk.

### 4.4 Custom sources (API/webhook)

Two complementary mechanisms:

1. **Generic JSON poller**: user supplies a URL + optional auth header + a tiny mapping (JSONPath/keypaths for id/title/url/timestamp). App polls it like any connector. Zero infrastructure.
2. **Local push**: a localhost HTTP listener (`Network.framework`) + the `inchill` CLI for same-machine producers (terminal, Claude Code hooks — see §6.8).
3. **(Deferred)** a tiny **Cloudflare Worker relay** for remote push (Notion webhooks, Zapier/automation bridges). Decision: not in v1 — nothing currently needs it, and v1 ships with zero infrastructure. The connector protocol won't change when it lands.

## 5. UX design

### 5.1 The panel

- Status item: template-style glyph + badge per the four-mode setting (total / high-signal / dot / none; default high-signal). Icon states: idle / unread / error (subtle). Zero unread = clean icon.
- Click (or global hotkey, default **⌥⌘I**, customizable) opens the panel. Default view: **All, grouped by source, sticky section headers**, with a segmented scope control at top: **All · per-source filter chips (⌘1…⌘9)**. Both stated modes — "all grouped by app" and "each app in its own tab" — are the same list with a filter.
- Panel anatomy top-to-bottom: **Pinned** section (if any) → active queue → collapsed **Snoozed** section → footer.
- Each row: source icon, title (e.g. "Maria mentioned you in #growth"), snippet, relative time. Hover reveals quick actions: **Open**, **Done**, **Snooze ▾**, **Pin**.
- Footer: "Refresh", per-source sync status/last-sync, Archive, Settings gear.
- **Keyboard-first**: arrows to move, ⏎ open, ⌘⏎ open + done, E done, S snooze, ⌘P pin, ⌘Z undo-done, ⌘1…⌘9 source filter, type-to-filter. Esc closes.
- **Copy behavior**: ⌘C on a row copies a rich representation (URL + title as RTF/HTML, plain text fallback). Rows are draggable — dragging a row out yields a URL (drop into Notes, a Slack message, a Linear comment).

### 5.2 Windows and app structure

- The panel is the primary surface, but there is also a **real Settings window** (⌘,, standard toolbar-style tabs: General, Sources, Appearance, Shortcuts) — not a cramped popover form.
- Optional **main window** ("Open as Window" / ⌘0) showing the same queue as a resizable, multi-column table for triage sessions — this is where a menu bar app quietly becomes Mac-arsed: sortable columns, multi-select, contextual menus, toolbar customization.
- Proper **menu bar menus** even though it's an LSUIElement-style app when in the panel: when the main window is open, full App/File/Edit/View/Window/Help menus with every command reachable and shortcut-labeled.

### 5.3 State preservation

Remember: filter scope, snoozed-section disclosure, main-window scope/sort (SceneStorage), window frame, snoozes (obviously). Restore on relaunch. *Amendment: panel size is fixed (MenuBarExtra window-style panels aren't user-resizable) — the original "remember panel size" promise is dropped; the ⌘0 window is the resizable surface.*

### 5.4 Triage semantics, notifications & focus

- **Open ≠ done** (except sources that clear themselves — Slack unreads auto-clear when Slack's own read-state says so, observed via the connector, never inferred from our "open" action). Everything else requires explicit done. Items die deliberately, not as a side effect.
- **Done → 90-day archive** (searchable, ⌘Z restores), then purge. **Pinned items are immortal** until unpinned.
- **Banners**: silent by default, per-source opt-in; Claude/terminal sources on by default (they're time-sensitive: a blocked session is wasted flow). Waking snoozes always banner. Focus modes respected.

## 6. Per-service feasibility (pressure-test)

Verified against current documentation, August 2026:

| Source | Verdict | Transport | Mark read? | Notes |
|---|---|---|---|---|
| Linear | ✅ 1:1 inbox mirror | Poll (30–60s, cheap) | ✅ + remote snooze | Best connector; build first |
| GitHub | ✅ Full inbox | Poll (`X-Poll-Interval`, 304s free) | ✅ | Needs **classic** PAT, `notifications` scope |
| Reminders | ✅ Native (deprioritized) | Push (EventKit change notifications) | ✅ (complete) | Covered today by RemindersMenubar; build later |
| Terminal / Claude Code | ✅ Hooks + local CLI | Push (localhost listener) | local | Claude Code `Notification`/`Stop` hooks → `inchill` CLI |
| Slack | ✅ Mentions/unreads · ❌ Later · ✅ emoji-save | Push (Socket Mode) after seed | ✅ (`conversations.mark`) | Internal app = exempt from 2025 limits; may need workspace-admin install approval; `reaction_added` replaces Later |
| Notion | ⚠️ Approximation | Webhook (comments) + poll (assigned-to-me) | ❌ (local only) | No inbox API exists; needs relay for webhooks |
| ~~Campsite~~ | **Removed 2026-08-19** | — | — | Was: poll v1 `notifications`; needed a Doorkeeper app on Buffer's instance. See §6.5. |
| Custom | ✅ By design | Poll or relay push | local | §4.4 |
| Sentry | ✅ Best-shaped since Linear | Poll (issues, `sort=inbox`) | ✅ (resolve/ignore) | Paste a user auth token; `is:for_review` *is* the queue. Cursor pagination → needs `snapshotWasComplete()`. §6.11 |
| Apple Mail | ✅ AppleScript | Poll (cheap unread-count probe, then enumerate) | ✅ (read/flag) | Covers Gmail, which is already an IMAP account in Mail.app. 12s cold / 0.15s warm; `~/Library/Mail` is TCC-blocked. §6.12 |
| Gmail | ❌ Not building | — | — | Restricted scopes → CASA; testing tokens die in 7 days; per-user Google Cloud project is worse than the OAuth §6.9 rejected. §6.13 |

### 6.1 Slack — ✅ Viable (mentions + unreads), ❌ Saved-for-Later

**Verdict: better than expected.** Your instinct was right that Later is closed off, but mentions/unreads are fully buildable.

- **What works (official, user-token app):** Create a personal Slack app installed only to the Buffer workspace with user scopes (`channels:read/history`, `groups:read/history`, `im:*`, `mpim:*`). This counts as an **internal customer-built app**, which Slack explicitly exempted (June 3, 2025 clarification) from the harsh May-2025 non-Marketplace rate limits (1 req/min on `conversations.history` only hits *distributed* apps). Internal apps keep Tier 3 limits.
- **Real-time, no server needed:** **Socket Mode** works for personal apps (it's explicitly disallowed for Marketplace apps — it's *the* internal-app feature). Subscribe to user `message.*` events over WebSocket using an app-level `xapp-` token + your `xoxp` token. So the Slack connector can be push-based: enumerate conversations once (`users.conversations`), seed unread state (`conversations.info` gives `unread_count` for DMs; for channels compare `last_read` vs latest ts), then maintain counts and detect @-mentions incrementally from events. No polling treadmill.
- **No "give me all unreads" endpoint exists** — the seed-then-track approach above is the standard workaround.
- **Saved for Later: no API, full stop.** `stars.list` is deprecated and frozen at pre-2023 data; Slack says "Later APIs are not currently available." The only route is undocumented client endpoints (`client.counts` with browser `xoxc`/`xoxd` tokens) — tokens rotate constantly and Slack has been flagging their use as a security threat on corporate workspaces in 2025–2026. **On your employer's workspace, don't.** Scope Later out; use mentions/unreads/DMs as the Slack vector.
- **Gate to clear first:** if Buffer's workspace has "Require App Approval" on, you can't install even your own app without an admin approving it. Check this before writing the connector — build the app skeleton, attempt install, see if Slackbot asks an owner. (Worst case: pitch it internally; it's read-only on your own account.)

**The Later gap — verified dead ends and the one live path (Aug 2026):**

- **Message reminders won't surface as unreads.** Since the Later redesign (2023), a due "remind me about this message" no longer sends the historical Slackbot DM — it's only a banner notification + badge on the Later/Activity tabs, which the API can't see. (Confidence medium-high, documented-by-omission; worth a 5-minute empirical test — set a 1-minute reminder, poll the Slackbot IM — before fully closing the door.)
- **`reminders.*` APIs are formally deprecated** ("degraded or useless" per Slack's own changelog) and likely blind to reminders created via the Later UI. Don't build on them.
- **Zapier's "New Saved Message" trigger is a trap:** still listed, but broken for DM saves since 2023 and returning fake test data as of Nov 2025 community reports. Slack has no Workflow Builder / Events API / webhook trigger for Later saves at all; Make and IFTTT have nothing either.
- **The live path: an emoji reaction as the save gesture.** `reaction_added` is a fully supported user event — and our Socket Mode connector *already receives events*. Pick a signature emoji (configurable; default `:pushpin:` 📌); reacting to any message creates an item in the app with the permalink (`chat.getPermalink`), title from the message text, and the reactor check `user == me`. Removing the reaction (`reaction_removed`) clears it. This needs **zero extra infrastructure** — no Zapier, no relay — and is arguably better than Later: one keystroke on any message, visible to the API, reversible, and it works from mobile Slack too.
### 6.2 Linear — ✅ Ideal citizen (true 1:1 inbox mirror)

The best connector in the app; build it first.

- The GraphQL API exposes **exactly the Inbox**: `notifications(first, filter, orderBy)` returns the authenticated user's notifications with `type` (`issueMention`, `issueAssignedToYou`, `issueNewComment`…), `readAt`, `snoozedUntilAt`, `archivedAt`, `actor`, `title`, `subtitle`, `url`, and the concrete issue/project/document. Unread = `readAt == null && snoozedUntilAt == null && archivedAt == null`.
- **Write-back is full-fidelity:** `notificationUpdate` (mark read, snooze remotely — Linear snooze can be *real*, not local-only), `notificationArchive`, `notificationMarkReadAll`.
- **Auth:** personal API key (sanctioned for individual use, acts as your user, `Authorization: <key>` — no Bearer prefix). Rate limit 2,500 req/hr — polling every 30–60s is trivial.
- **No push:** webhooks don't cover notifications and require workspace-admin creation anyway; the `notificationCreated` GraphQL subscription exists in the schema but is undocumented/unsupported. **Poll and diff.** 30s cadence feels real-time in practice.

### 6.3 Notion — ⚠️ Approximation only; **demoted to build-on-demand**

> Decision: no numbered milestone. Brandon's continued Notion use is itself uncertain, and the good version of this connector wants the deferred relay. If/when wanted, the facts below hold.

Confirmed: the public API has **no notifications/inbox endpoint** and no mention webhook event. The Notion vector is a synthesis of three things:

1. **Webhook `comment.created`** (integration webhooks are GA, HMAC-verified, need a public HTTPS receiver — this is a second use for the Cloudflare Worker relay in §4.4): on each event, fetch the comment, check if your user ID is in the rich-text mentions → synthesize a "mentioned in comment" item. Closest possible thing to Inbox mentions, and it's push.
2. **Poll task databases with the people filter `"me"`** (added March 2026 — no hardcoded UUID needed): Assignee contains me, Status != Done → "assigned to you" queue.
3. Fallback if hosting a receiver is unwanted: poll Search sorted by `last_edited_time` + `List comments` on recently edited pages (comments are per-page only — there is no global "comments mentioning me" query).

**Caveat:** an integration only sees pages explicitly shared with it. Coverage requires sharing the relevant teamspaces with the integration — do this once, document it in-app ("Notion source: 3 teamspaces connected").
### 6.4 GitHub — ✅ Easy, with one auth gotcha

- `GET /notifications` returns the whole personal inbox with a `reason` per thread (`review_requested`, `mention`, `assign`, `author`, `team_mention`, …) — review requests, mentions, and assignments in one endpoint. Mark read via `PATCH /notifications/threads/{id}`; mark done via `DELETE`.
- **The endpoint is built for polling:** send `If-Modified-Since`, honor the `X-Poll-Interval` header (~60s), and `304 Not Modified` responses are *free* (don't count against the 5,000/hr limit).
- **Gotcha:** fine-grained PATs *still* can't call the notifications API in 2026 — there's no notifications permission at all. You need a **classic PAT with the `notifications` scope**. Check whether Buffer's org enforces SSO authorization on classic PATs (usually just a one-click authorize).
- No GraphQL notifications, no personal-notification webhooks. Poll; it's the canonical pattern (Gitify, Trailer, etc. all do this).

### 6.5 Campsite — REMOVED 2026-08-19 (analysis kept)

> **The connector is gone from the app.** Brandon paused it indefinitely
> rather than spend a teammate's time on *"an internal tool we're likely
> going to sunset"*, and removed it outright before sharing the app with
> teammates who have no Campsite at all. `CampsiteConnector.swift` and its
> catalog entry are deleted; nothing else referenced it.
>
> **The findings below stand and are why it is not worth rebuilding on a
> whim** — they were verified against the private fork's source, and
> re-deriving them would cost the same day again. If it ever comes back, the
> route is a Doorkeeper token against v1; v2 still cannot see a notification
> inbox.

#### Original analysis — Feasible, but via the internal API, not the public one

Campsite the hosted product wound down Feb 2025; the code is open source (CC BY-NC, with self-hosting explicitly allowed — Buffer's situation). That cuts both ways: the API is knowable down to the controller source, but nothing will ever improve upstream.

- **The public v2 API cannot see your inbox.** Its API keys are integration/bot-scoped and the surface is posts/comments/threads/messages/projects/members + webhooks — no notifications, no follow-ups.
- **The internal v1 API has exactly what we want**: `GET /v1/.../notifications` (with `unread`, `filter=home|grouped_home|activity`, cursor pagination), mark-read endpoints, and `follow_ups` (index/update/destroy). But v1 auth is user-session or first-party OAuth (Doorkeeper) — not designed for third-party clients.
- **Buffer's deployment already has an MCP layer** exposing `list_notifications`, `list_follow_ups`, `mark_notification_read` — i.e., someone at Buffer already solved user-level notification access once. Paths, best-first:
  1. Ask whoever maintains Buffer's Campsite fork to register a Doorkeeper OAuth app (it's a rails console one-liner) → clean token auth against v1.
  2. Point the connector at the same backend the MCP server uses.
  3. Session-cookie auth as a stopgap (fragile; cookies expire).
- Since it's Buffer-internal anyway, this is a conversation, not a technical blocker.

### 6.6 Apple Reminders — ✅ Trivial, but deprioritized (RemindersMenubar already covers it)

> Brandon already uses RemindersMenubar daily, so this connector is a nice-to-have for "one panel to rule them all" completeness, not an early milestone. The EventKit facts below stand whenever we want it.

- **EventKit, unchanged through macOS 26 Tahoe.** `requestFullAccessToReminders()` (macOS 14+ API), `predicateForReminders(in:)` + `fetchReminders(matching:)`. No new framework; nothing to wait for.
- Requirements: `NSRemindersFullAccessUsageDescription` in Info.plist (mandatory — crashes without it); if sandboxed, the `com.apple.security.personal-information.calendars` entitlement (it gates the XPC agent serving both Calendars *and* Reminders — without it EventKit silently returns nothing). Reminders is full-access-or-nothing (no write-only tier), which is fine.
- Bonus: EventKit posts change notifications (`EKEventStoreChanged`), so this connector is push-based for free — no polling.

### 6.7 Custom sources — ✅ By design (relay parts deferred)

Covered by §4.4: the generic JSON poller handles anything that can serve a JSON list; the localhost listener handles same-machine push. Any internal tool that can serve or POST JSON becomes a source with zero app changes.

When the deferred relay lands, it additionally unlocks **remote push and automation-platform bridges** (Zapier, Make, Slack Workflow Builder, cron scripts), each with its own URL + secret. Not in v1.

### 6.8 Terminal & Claude Code — ✅ Buildable with hooks, no scraping

The Vibe-Island-style feature: surface "Claude is waiting for you" / "your long build finished" alongside SaaS notifications.

**Mechanism — local push, not notification scraping:**
- The app runs a **localhost HTTP listener** (`Network.framework`, `127.0.0.1`, random port + bearer token stored in Keychain) — this is the same local ingestion path already sketched in §4.4, promoted to a first-class feature.
- Ship a tiny bundled CLI, **`inchill`** (installed via Settings → "Install command-line tool", like VS Code's `code`): `inchill notify --source claude-code --title "Waiting for permission" --body "..." --focus-tty $TTY`. It POSTs to the listener; the app renders it as an item.

**Claude Code specifically** — first-class hook support, zero hacks:
- `~/.claude/settings.json` hooks: the **`Notification`** hook fires exactly when Claude Code wants the user (permission requests, idle-waiting-for-input) and the **`Stop`** hook fires when a response completes. Both run any command with a JSON payload on stdin (session id, cwd, message). Pipe to `inchill`.
- **One row per session, not per turn** (0.3.2). `Notification`/`Stop` upsert `claude-<session_id>`; **`UserPromptSubmit`** and **`SessionEnd`** clear it. The queue therefore means "sessions awaiting my reply", and a long session occupies one row instead of one per turn. See CLAUDE.md for why `Stop` stays low-signal and why the hooks exit 0 when the app is closed.
- The app ships a one-click "Set up Claude Code integration" that writes these hook entries.
- Items carry the session's cwd + terminal app; "Open" focuses the right terminal window (NSWorkspace + recorded tty/bundle id). Auto-clear the item when the same session sends its next event (the wait is over).

**Stock Terminal / any shell:** no notification API exists, so integration is shell-level: a zsh `precmd` snippet (installable from Settings) reports completion of any command that ran longer than N seconds — `inchill notify --title "make: done (exit 0)"` — plus manual use: `long_command; inchill done "deploy finished"`.

**Rejected:** reading the macOS Notification Center database (requires Full Disk Access, private schema, breaks every macOS release) and Accessibility-API scraping. Hooks and shell integration are reliable and honest.

## 6.9 OAuth vs paste-a-token (explored 2026-08-17, verified against current docs)

| Provider | Verdict | Why |
|---|---|---|
| GitHub | ❌ Can't switch | Device flow is clean (no secret) — but `GET /notifications` **rejects OAuth App tokens entirely**; GitHub's docs state the endpoint supports "personal access token (classic)" only. Same wall as fine-grained PATs. Classic PAT paste is the only working auth. Recheck occasionally. |
| Slack | ❌ Pointless here | OAuth v2 requires **HTTPS redirect URIs** (no localhost/custom scheme), impossible for a serverless native app. And since every user installs their *own* workspace app, Slack's install page already runs the OAuth flow and displays the xoxp token — paste is the flow's last step, not an alternative to it. The `xapp` Socket Mode token can never come from OAuth. |
| Linear | ⚠️ Viable, optional | PKCE public-client flow (no secret) with documented `http://localhost` loopback redirect; 24h tokens + refresh; near-identical rate limits. Requires registering a Linear OAuth app (client_id) first. The personal API key remains Linear's sanctioned personal path and is fewer steps — implement OAuth only if/when the GitHub release wants nicer onboarding. Sandbox note: the loopback listener would need `network.server` entitlement if the app is ever sandboxed. |

**Decision (final, 2026-08-19): every source is paste-a-token; Linear PKCE was implemented and then removed.** Brandon's call — *"Let's remove the 'sign in with Linear' option for auth, personal API token is fine."* The table's original verdict was right and the 2026-08-17 supersession below was the mistake: OAuth still required the user to register their own Linear application and paste its client ID, so it traded one paste for a longer setup, a fixed loopback port, and a token that expires. `LinearOAuth.swift`, the auth-method picker and the token refresh path are gone; the source editor renders Linear like every other paste-a-token source and its `authNote` records this. Leftover `oauth*` Keychain material is cleared the next time a Linear source is saved. **If OAuth is ever revisited for a public release, the argument to beat is "fewer steps", not "more standard".**

**Decision (superseded 2026-08-17, reverted 2026-08-19): Linear PKCE is now implemented** — `LinearOAuth.swift`, loopback callback on fixed port 52180, bring-your-own client ID, tokens in Keychain with auto-refresh; the personal API key path remains the default/fewest-steps option. GitHub and Slack stay paste-a-token (verdicts above still hold), and the source editor now says why in-line.

## 6.10 Adding a source — what it actually costs (measured 2026-08-19)

Five touchpoints, in the order you write them:

1. `ConnectorCatalog.all` — fields (`isSecret`/`isToggle`), `setupSteps`, `setupURL`, `authNote`.
2. `ConnectorFactory.make` — one `case`.
3. The actor. Sizes already in the tree: **GitHub 260 lines** (poll + `markDone` + pagination), ntfy 342 (WebSocket push), Linear 535 + 136, Slack 1,397. A well-behaved REST poller is **~200–300 lines**, and `GitHubConnector` is the template.
4. Optionally `AppState.openable(_:payload:)` — one case if the source has a desktop app worth landing in.
5. Tests against `nonisolated static` pure helpers (CLAUDE.md rule 5).

Three invariants cause all the damage:

- `.remoteTruth` **only** with a truthful `snapshotWasComplete()`. Cursor pagination with a page cap must answer `false` at the cap.
- `occurredAt` must be the **real event time**. `Store.resurrectIfNeeded` revives a done item when `remote.occurredAt > doneAt`, so a `.now` fallback makes items immortal (§6.11).
- Every failure gets a named reason (rule 4).

### The three escape hatches — check these before writing a connector

The app already ships three generic paths: **`jsonPoller`** (anything serving a JSON list), **`ntfy`** (anything that can POST a webhook — most SaaS alerting can target a topic), and **`inchill`** (anything on this Mac, including Mail rules and cron). Build a native connector only where all three fail: you need write-back read-state, a desktop deep link, or auth the poller can't express.

## 6.11 Sentry — ✅ the best-shaped source added since Linear

> **Verified against the real service 2026-08-20**: Brandon pasted a token and
> org slug and the source returned issues. Still unexercised: the resolve
> write-path (it is opt-in and defaults off) and cursor pagination (only past
> 100 issues).

- **Auth:** user auth token, `Authorization: Bearer …`, scope `event:read` (+ `event:write` to resolve). Nothing to register, no OAuth.
- **The queue is one call:** `GET /api/0/organizations/{org}/issues/?query=is:unresolved is:for_review&sort=inbox`. Sentry's own "For Review" concept *is* this app's queue.
- **Fields map directly:** `id`, `title`, `culprit`, `shortId`, `permalink`, `lastSeen`, `firstSeen`, `level`, `count`, `project`, `substatus`.
- **markDone is real:** `PUT …/issues/?id=…` with `{"status":"resolved"}` (or `"ignored"`), so `[.markDone, .remoteTruth]`.
- **Gotcha:** cursor pagination via the `Link` header, `limit` max 100 — needs a real `snapshotWasComplete()`, exactly like GitHub's.
- No desktop app (`sentry://` resolves to nothing — verified), so the web `permalink` is the right open.

**Plan availability (Brandon's concern, 2026-08-19):** *"it sucks that their API is locked out of the free plan."* Checked — the REST API is **not** plan-gated; the free Developer plan includes API access, and what the tier limits is event quota and rate limits. Worth one curl against his own org before trusting this paragraph over his experience.

### The jsonPoller timestamp bug — found here, fixed in this change

Sentry's issues endpoint returns a JSON array, so `jsonPoller` handles it with the mapping `id=id,title=title,url=permalink,body=culprit,time=lastSeen`. Except `lastSeen` carries fractional seconds, and the two `ISO8601DateFormatter` option sets are **mutually exclusive** — verified:

```
2026-08-19T12:34:56.789Z | default: nil | fractional: OK
2026-08-19T12:34:56Z     | default: OK  | fractional: nil
```

The parse returned `nil`, `occurredAt` fell back to `.now`, and because `jsonPoller` has `.remoteTruth` but no `.markDone`, `resurrectIfNeeded` saw `occurredAt > doneAt` on **every poll** and revived the item. It could not be dismissed. With the timestamp parsed the same mechanism becomes the desired behaviour — the item returns when the error actually recurs.

## 6.12 Apple Mail — ✅ viable via AppleScript, and it is also the Gmail answer

> **Verified against the real service 2026-08-20**, but only after 0.3.1.
> 0.3.0 shipped broken twice over: the hardened runtime blocked every Apple
> event because the app carried no
> `com.apple.security.automation.apple-events` entitlement (-1743, and macOS
> never offered the Automation prompt, so there was nothing to allow), and
> `markDone` used `first message … whose`, which raises "Invalid index"
> (-1719) whenever the lookup misses. Both fixed in 0.3.1; see CLAUDE.md
> rule 2. Still unexercised: the 100-message truncation path.

Verified on Brandon's Mac 2026-08-19: Automation permission already granted, Mail running, three IMAP accounts.

- **Every field a connector needs exists** — numeric `id`, RFC `message id`, `subject`, `sender`, `date received`, `read status`, `flagged status`. Properties need explicit `as text` coercion, and references out of a `whose`-filtered list are finicky — re-resolve by `id`.
- **`message://<Message-ID>` resolves to Mail.app (verified)** — an exact-message deep link, same shape as `slack://`, and local so it needs no https fallback.
- **markDone is real** (`set read status`, `set flagged status`), so `[.markDone, .remoteTruth]`.
- **Timing is the whole design constraint**, measured: `unread count of inbox` = **0.12s**, but `messages of … whose read status is false` = **12s cold, 0.15s warm**. The 12s is Mail waking on its first Apple Event after idle. A poll that reads a slow first call as failure will report a broken source after every quiet spell. **Probe the cheap count; enumerate only when it changes.**
- **The Envelope Index SQLite route is dead:** `~/Library/Mail` is TCC-protected — `ls` returns "Operation not permitted" — so it needs Full Disk Access on top of a private schema that breaks every macOS release. Same rejection as the Notification Center DB in §6.8. AppleScript is the honest path.
- **Silent-failure risk (rule 4):** Apple Events needs `NSAppleEventsUsageDescription` and a per-target Automation grant. Denied is `errAEEventNotPermitted` (**-1743**) and it looks exactly like an empty inbox. Surface it by name with the Privacy › Automation deep link.
- **The scoping question:** "unread in INBOX" is thousands of items for most people and would drown the queue. The default is narrow — **flagged only** — with unread-in-a-named-mailbox as the opt-in.

**Zero-code variant worth knowing:** a Mail rule can run an AppleScript, so a rule calling `inchill notify` makes email *push* through the existing local source with no connector at all. Kept as the fallback if the polled connector proves annoying.

## 6.13 Gmail — ⚠️ the one source that cannot be paste-a-token

**Decision (2026-08-19): not building it.** Build §6.12 instead — Gmail is already one of the three IMAP accounts in Mail.app.

- Gmail API scopes are **restricted** → CASA Tier 2 assessment by a Google-approved lab, revalidated yearly, for public distribution.
- **Testing mode is unusable:** refresh tokens expire after 7 days regardless of use.
- An **Internal** Workspace app escapes both — fine on buffer.com, but every other user would have to create their own Google Cloud project. That is **strictly worse than the Linear PKCE flow §6.9 already rejected** for trading one paste for a longer setup. The argument to beat is still "fewer steps".
- App-password IMAP is the only paste-a-token path — still supported in 2026, needs 2-Step Verification, and a Workspace admin can disable it org-wide. But **Foundation has no IMAP client**, so it means a second package dependency (the app has exactly one) or hand-writing IMAP IDLE. Highest cost of anything in this section.

Revisit only for Gmail-specific selectors (`is:important`, labels, priority inbox) or an account deliberately kept out of Mail.app.

## 6.14 Notion — ⚠️ §6.3's verdict stands, unchanged by the 2026 API

Webhooks shipped with API version `2026-03-01` and are GA, but they cover page/database/comment events, require a **public HTTPS receiver** with `X-Notion-Signature` validation, and explicitly exclude user and permission changes. There is still **no notifications/inbox endpoint**, and comments remain per-page with no workspace-wide "mentions me" query.

- **The comments half wants the deferred relay.** Don't fake it.
- **The poll half needs nothing:** data source query + people filter `"me"` + status != Done = an honest "assigned to you" source. Half a Notion connector, clearly labelled, beats a comments connector that cannot see comments.
- New fact: **`notion://` resolves to Notion.app (verified)**, so items can land in the desktop app via `AppState.openable`, with the https URL riding in the payload for Macs without Notion.

Unchanged caveat: an integration sees only pages explicitly shared with it, so coverage is a setup step to state in-app.

## 6.15 Other candidates — ranked, with Brandon's verdicts (2026-08-19)

| Source | Verdict | Why |
|---|---|---|
| **PagerDuty** | ⏸ Wanted, **untestable** | Best-shaped of the lot: personal API token, `assigned_to_user` returns *only* triggered/acknowledged so the endpoint is the queue, status transitions are a real `markDone`. |
| **Jira** | ⏸ Wanted, **untestable** | Email + API token basic auth, JQL `assignee = currentUser() AND resolution = Unresolved`. |
| **Zendesk / Intercom** | ⏸ Wanted, **untestable** | "Assigned to me, not solved." Zendesk email/token basic auth; Intercom a bearer token. |
| **Stripe** | 🔜 Interesting, Brandon's word | Restricted key; `/v1/disputes` plus `/v1/events` is a real event feed, and a dispute has a deadline. |
| **Calendar (EventKit)** | ✅ Cheap, free push | Same story as Reminders §6.6 — `EKEventStoreChanged` means no polling. Covers Google Calendar because it is already in Calendar.app. |
| **Things 3** | ✅ Local, no auth | AppleScript/URL scheme, used daily. The §6.6 "RemindersMenubar already covers it" argument does **not** apply — Things has no menu bar queue. `things3-cli` is not installed on this Mac. |
| **Vercel / Cloudflare / Netlify** | ✅ but use `jsonPoller` | Deployments filtered to `state=ERROR` is a JSON list with a timestamp. Promote to native only for the deploy-log deep link. |
| **Buffer** | ❌ Not yet | A failed post *is* a notification, but per Brandon: *"Buffer doesn't have a notification webhook offering yet."* Revisit if that ships. |
| **Figma** | ⚠️ Notion-shaped | PAT pastes fine, but comments are per-file (`/v1/files/:key/comments`) with no inbox, and the `FILE_COMMENT` webhook needs the relay. Approximation only. |

**⏸ "Untestable" is a real blocker, not a shrug.** Brandon: *"Pagerduty, zendesk, intercom, JIRA all feel good and necessary but I can't test them."* This repo's rule is that a connector never fed to the real service is unverified however carefully written (CLAUDE.md rule 3). Don't ship one of these off documentation alone — either get a trial account first, or leave it and let `jsonPoller` cover the case.

**Explicit noes, so they don't get re-litigated:**

- **Discord** — the user-token API violates ToS, and a bot token cannot see your DMs. Same shape as the `xoxc`/`xoxd` verdict in §6.1.
- **Mixpanel / Amplitude alerts** — no personal notification API; they alert by email and Slack, so they already arrive through those sources.
- **GitHub Actions** — already arrives as `ci_activity`, handled by `GitHubConnector.humanize`. Don't rebuild it.

## 7. Milestones

- **Day 0 (before any code)**: create the Slack app from a manifest and attempt install on Buffer's workspace (approval latency is the schedule risk); ask the Campsite maintainer about a Doorkeeper OAuth app.
- **M0 — Skeleton** (the app feels real immediately): Xcode project (`lol.bgreen.inboxandchill`, macOS 15 target), `MenuBarExtra` window-style panel, SwiftData item store, `Connector` protocol + a fake connector generating items, triage verbs end-to-end on fake data (done/⌘Z/snooze/pin/archive), keyboard nav, Settings window shell, Keychain wrapper, ⌥⌘I hotkey.
- **M1 — The sure things**: **Linear** (poll `notifications`, mark-read + remote snooze) and **GitHub** (classic PAT, `If-Modified-Since` polling). Deep links, per-source filters, badge modes. *At M1 the app is already daily-usable.*
- **M2 — Slack**: Socket Mode connector (seed unread state, then event-driven), hybrid auto-clear from Slack read-state, 📌 emoji-save via `reaction_added`.
- **M3 — Campsite**: v1 notifications + follow-ups connector (token from Day-0 ask).
- **M4 — Local sources**: localhost listener + `inchill` CLI + one-click Claude Code hook setup (§6.8); generic JSON poller UI.
- **M5 — Mac-arsed pass**: main triage window (sortable table, multi-select), drag-out & rich copy, App Intents/Shortcuts ("Get my queue", "Snooze item"), launch-at-login, state restoration audit, full Mac behaviour test plan (menus, VoiceOver, light/dark, multi-display); Developer ID signing + notarization pipeline for the eventual GitHub release.
- **M6 — Sentry + Apple Mail** (2026-08-19): the two sources Brandon prioritised after the §6.10–6.15 exploration. Sentry is the clean REST citizen; Apple Mail is the one that also answers Gmail.
- **Backlog (build on demand)**: Notion poll-half (§6.14), Apple Reminders/EventKit and Calendar (§6.6/§6.15), Stripe (§6.15), Cloudflare relay + automation bridges (§4.4/§6.7). **Blocked on an account to test against, not on code**: PagerDuty, Jira, Zendesk, Intercom (§6.15).

## 8. Risks & open questions

| Risk | Status | Mitigation |
|---|---|---|
| Buffer Slack requires admin approval for custom apps | **Open — Day 0 ask** | Read-only personal app is an easy pitch; assumed quick per Brandon |
| Slack Saved-for-Later unavailable | **Confirmed — no API** | Scoped out; unofficial client-token route rejected (Slack flags it as a security threat on corporate workspaces) |
| Notion coverage gaps | Confirmed limitation | Approximation is honest: mentions via comment webhooks + assigned-to-me; label the source as partial in-app |
| ~~Campsite v1 auth~~ | **Closed — source removed 2026-08-19** | Was blocked on a Doorkeeper OAuth app from Buffer's instance maintainer |
| GitHub classic PAT + org SSO | Minor | One-time SSO authorization of the PAT |
| Polling battery cost | Design-level | Only Linear/GitHub (+ optional pollers) poll, 30–60s, cheap; Slack/local sources are push. Coalesce timers; pause polling when screen locked |
| Relay = infrastructure | **Deferred out of v1** | Nothing in v1 needs it; Notion (its main customer) is demoted; connector protocol unchanged when it lands |
| Sharing = Slack rate-limit trap for users | Designed around | Distributed Slack apps get 1 req/min; shared users create their own internal app from our bundled manifest (BYO app/tokens) |
