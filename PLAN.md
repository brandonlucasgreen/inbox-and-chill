# Inbox & Chill — Plan

*A native macOS menu bar app that aggregates your unread/actionable queue across Slack, Linear, GitHub, Campsite, Notion, terminal apps (incl. Claude Code), and custom sources.*

> Status: v2 — feasibility verified against current API docs (Aug 2026); product decisions locked via grill-me session (2026-08-17).

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
5. **Snooze**: write-through for Linear (real remote snooze), local for the rest, identical UI; snoozed items visible in a collapsed section; a waking item always banners (snoozing is consent to be interrupted).
6. **Done items archive for 90 days** (searchable, ⌘Z undo-done), then purge. **Pin (⌘P)** exempts an item from *all* auto-clears, done, and purge — pinned section at top of panel, leaves only by unpinning.
7. **Distribution**: personal-first, built for eventual GitHub release ("I very much want to share this"); Developer ID + notarization, **no App Sandbox** (it fights the terminal/CLI features); App Store at most a later degraded fork. Shared users bring their own Slack app via a bundled manifest (keeps everyone in Slack's internal-app rate-limit tier) and their own PATs/keys.
8. **Cloudflare relay deferred; Notion connector demoted to build-on-demand** (Notion's tenure in the stack is itself uncertain). v1 is fully self-contained — zero infrastructure.
9. **Slack save emoji**: configurable, default 📌 `:pushpin:`. Slack app created + install attempted immediately.
10. **Naming**: app **Inbox & Chill**, CLI **`inchill`**, bundle ID **`lol.bgreen.inboxandchill`**.
11. **Panel defaults**: All view grouped by source with sticky headers; global hotkey customizable, default **⌥⌘I**.
12. **macOS 15 (Sequoia) minimum**; dev machine is 26 (Tahoe). Gate any future 26-only API per-feature, not app-wide.
13. Apple Reminders connector deprioritized (RemindersMenubar already serves it).

## 3. Mac app classification (per the Mac-arsed workflow)

**Shape**: utility / menu bar app, backed by a lightweight shoebox (a local store of notification items). Closest kin: Reminders MenuBar, Fantastical's menu bar mode, CodeEdit's… no — closest kin is actually **GitHub's old Trailer app** and **Mailplane-style unified badge counts**, but done as a first-class 2026 SwiftUI app.

**Core objects**:
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

Remember: filter scope, group-by mode, panel size, window frame, sort order, per-source collapsed state, snoozes (obviously), last selection. Restore on relaunch.

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
| Campsite | ⚠️ Internal-API conversation | Poll v1 `notifications` | ✅ (v1) | Public v2 API can't see inbox; needs a Doorkeeper app on Buffer's instance |
| Custom | ✅ By design | Poll or relay push | local | §4.4 |

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

### 6.5 Campsite — ⚠️ Feasible, but via the internal API, not the public one

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
- The app ships a one-click "Set up Claude Code integration" that writes these hook entries.
- Items carry the session's cwd + terminal app; "Open" focuses the right terminal window (NSWorkspace + recorded tty/bundle id). Auto-clear the item when the same session sends its next event (the wait is over).

**Stock Terminal / any shell:** no notification API exists, so integration is shell-level: a zsh `precmd` snippet (installable from Settings) reports completion of any command that ran longer than N seconds — `inchill notify --title "make: done (exit 0)"` — plus manual use: `long_command; inchill done "deploy finished"`.

**Rejected:** reading the macOS Notification Center database (requires Full Disk Access, private schema, breaks every macOS release) and Accessibility-API scraping. Hooks and shell integration are reliable and honest.

## 7. Milestones

- **Day 0 (before any code)**: create the Slack app from a manifest and attempt install on Buffer's workspace (approval latency is the schedule risk); ask the Campsite maintainer about a Doorkeeper OAuth app.
- **M0 — Skeleton** (the app feels real immediately): Xcode project (`lol.bgreen.inboxandchill`, macOS 15 target), `MenuBarExtra` window-style panel, SwiftData item store, `Connector` protocol + a fake connector generating items, triage verbs end-to-end on fake data (done/⌘Z/snooze/pin/archive), keyboard nav, Settings window shell, Keychain wrapper, ⌥⌘I hotkey.
- **M1 — The sure things**: **Linear** (poll `notifications`, mark-read + remote snooze) and **GitHub** (classic PAT, `If-Modified-Since` polling). Deep links, per-source filters, badge modes. *At M1 the app is already daily-usable.*
- **M2 — Slack**: Socket Mode connector (seed unread state, then event-driven), hybrid auto-clear from Slack read-state, 📌 emoji-save via `reaction_added`.
- **M3 — Campsite**: v1 notifications + follow-ups connector (token from Day-0 ask).
- **M4 — Local sources**: localhost listener + `inchill` CLI + one-click Claude Code hook setup (§6.8); generic JSON poller UI.
- **M5 — Mac-arsed pass**: main triage window (sortable table, multi-select), drag-out & rich copy, App Intents/Shortcuts ("Get my queue", "Snooze item"), launch-at-login, state restoration audit, full Mac behaviour test plan (menus, VoiceOver, light/dark, multi-display); Developer ID signing + notarization pipeline for the eventual GitHub release.
- **Backlog (build on demand)**: Notion connector (§6.3), Apple Reminders/EventKit (§6.6), Cloudflare relay + automation bridges (§4.4/§6.7), App Store fork investigation.

## 8. Risks & open questions

| Risk | Status | Mitigation |
|---|---|---|
| Buffer Slack requires admin approval for custom apps | **Open — Day 0 ask** | Read-only personal app is an easy pitch; assumed quick per Brandon |
| Slack Saved-for-Later unavailable | **Confirmed — no API** | Scoped out; unofficial client-token route rejected (Slack flags it as a security threat on corporate workspaces) |
| Notion coverage gaps | Confirmed limitation | Approximation is honest: mentions via comment webhooks + assigned-to-me; label the source as partial in-app |
| Campsite v1 auth | **Open — needs a human** | Ask the internal maintainer for a Doorkeeper OAuth app; MCP layer proves user-level access is already solved once |
| GitHub classic PAT + org SSO | Minor | One-time SSO authorization of the PAT |
| Polling battery cost | Design-level | Only Linear/GitHub (+ optional pollers) poll, 30–60s, cheap; Slack/local sources are push. Coalesce timers; pause polling when screen locked |
| Relay = infrastructure | **Deferred out of v1** | Nothing in v1 needs it; Notion (its main customer) is demoted; connector protocol unchanged when it lands |
| Sharing = Slack rate-limit trap for users | Designed around | Distributed Slack apps get 1 req/min; shared users create their own internal app from our bundled manifest (BYO app/tokens) |
