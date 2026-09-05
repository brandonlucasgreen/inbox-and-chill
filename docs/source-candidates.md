# Candidate sources — what to integrate next (research, 2026-09-04)

Status: **research; §5 shipped.** Brandon's verdict, 2026-09-04: *"I would
build gitlab and trello and pagerduty next. apple calendar also seems like a
sleeper hit, but i don't feel it's as strong because calendar notifications
have nothing to act on - they are purely to be acknowledged - *and* are
definitionally time sensitive. so i would skip it"* — and, decisively:
*"i won't be able to test any of those 3 though because i don't have accounts
with any of them."*

So **Apple Calendar (§2) is dropped**, not deferred: a row you can only
acknowledge has nothing for `E`, `S` or `C` to mean. **PagerDuty is held**
behind §6.15's own rule rather than built blind, and `root=` (§5) is built
instead — it covers PagerDuty read-only today. GitLab and Trello are being
built **fixture-driven, with no live account**, which is a first for this repo
and is stated in each PR.

Asked for by Brandon:

> JIRA and pagerduty come to mind, but i would like you to research 5-10
> other tools we could integrate with. Requirements are that they are widely
> used saas services in tech or among indie developers/solopreneurs, have
> some kind of noisy notification scheme by default, and would provide
> utility by integrating into I&C.

Everything under **Verified** was read on 2026-09-04 from a primary artifact
— an OpenAPI document, an official docs page, or this Mac's own SDK — not
from memory. §7 lists what stays unverified. Both tools Brandon named are in
the shortlist and both check out, with gates.

---

## 1. The rubric, which is the repo's own

PLAN §6's escape-hatch rule decides most of this before any API is read:

> The app already ships three generic paths: **`jsonPoller`**, **`ntfy`** and
> **`inchill`**. Build a native connector only where all three fail: you need
> write-back read-state, a desktop deep link, or auth the poller can't
> express.

Four questions, in this order:

1. **Is there a per-user "what is waiting for me" endpoint?** Linear and
   GitHub have one, so their connectors are inbox mirrors. Jira and Asana do
   not, so theirs can only be *assigned-work* mirrors. That difference is the
   single biggest determinant of how good a source feels.
2. **Can it be paste-a-token?** §6.9's final decision is that every source
   is. A provider needing an OAuth app per user, or an admin's blessing, is a
   Campsite (§6.5, removed) rather than a Sentry.
3. **Is there write-back read-state?** Without it, `E` is local-only and the
   source is a candidate for `jsonPoller` instead of code.
4. **Does the snapshot know when it is complete?** `.remoteTruth` archives
   anything absent, so a paged list needs a truthful `snapshotWasComplete()`.

## 2. The shortlist

Ranked by (utility × fit) ÷ effort. "Inbox API" means a per-user feed of
things wanting your attention, not a list of work items.

| Tool | Inbox API | Write-back | Verdict |
|---|---|---|---|
| **GitLab** | ✅ To-Dos | ✅ mark done | **Build first** |
| **Apple Calendar** | ✅ EventKit | n/a | **Sleeper pick** |
| **Trello** | ✅ notifications | ✅ unread flag | Strong |
| **PagerDuty** | ✅ incidents | ✅ ack/resolve | Strong, 2 gates |
| **Jira** | ❌ JQL only | ❌ none | Good, honest limits |
| **Asana** / ClickUp | ❌ tasks only | ✅ complete | To-do source |
| **Stripe** | ~ events | ❌ none | Indie money queue |
| **Help Scout** / Front | ✅ assigned | ✅ status | Needs token refresh |
| **incident.io** | ✅ incidents | ✅ status | Org-key gate |
| Vercel / Netlify / Railway | ❌ | ❌ | Escape hatch (§5) |

### GitLab — build this one first

**Verified:** `GET /todos` is the authenticated user's To-Do list, filterable
by `action` (`assigned`, `mentioned`, `build_failed`, `marked`,
`approval_required`), `state`, `type` (`Issue`, `MergeRequest`, `Epic`,
`AlertManagement::Alert`, `Vulnerability`), project and author. Each item
carries `id`, `action_name`, `target_type`, `target`, `target_url`, `body`,
`state`, `created_at`, `updated_at`. Write-back is
`POST /todos/:id/mark_as_done` and `POST /todos/mark_as_done` for all. Auth is
a personal access token in a `PRIVATE-TOKEN` header.

**This is a Linear-class 1:1 inbox mirror** — the same shape as the best
connector in the app, capabilities `[.markDone, .remoteTruth]`, `target_url`
for the open, `created_at` for `occurredAt`. `build_failed` is CI noise that
belongs in a triage queue and is exactly what nothing else here surfaces.

Two traps:

- **`read_api` is GET-only, so the write-back needs the full `api` scope.**
  Ask for `api` in the setup steps or `E` fails at the moment it matters.
- **A GitLab.com PAT expires — 365 days by default, and the date is
  mandatory.** No other source in the app has an expiring credential. Rule 5
  applies: the 401 has to name "your GitLab token expired" and not read as an
  empty inbox.

### Apple Calendar via EventKit — the sleeper pick

Not on Brandon's list, and per line of code it is the best value here.

**Verified on this Mac:** `requestFullAccessToEventsWithCompletion` exists on
macOS 14+ in the SDK's own `EKEventStore.h`, beside the
`requestFullAccessToRemindersWithCompletion` the app already calls;
`EKEntityTypeEvent` is the sibling of the reminders entity;
`NSCalendarsFullAccessUsageDescription` is real and macOS 14+.

**Why it matters:** this is the Apple Mail trick applied to calendars.
Google Calendar and Outlook both sync into Calendar.app, so a local EventKit
source covers the SaaS calendars **without touching Google's OAuth**, which
is the wall that killed Gmail (§6.13). The measured Reminders findings carry
over: **no entitlement**, and no cold penalty. It reuses
`Connectors/Todo/`'s seam — provider in, `[TodoTask]`-shaped values out.

The one real design question is what a calendar row *is*. A meeting is not a
notification and not quite a to-do: it wants "in 12 minutes" urgency, a
`meet` link to open, and to leave the queue when it ends. That is a third
shape, so it needs its own decision rather than a copy of `reminders`.

### Trello — a real notification inbox

**Verified:** `GET /members/{id}/notifications` is the per-user feed, and each
notification carries `id`, `unread`, `type`, `date`, `dateRead`, `data`,
`card`, `board`, `idMemberCreator`, `reactions`. Write-back exists both ways:
`PUT /notifications/{id}` with an `unread` boolean, and
`POST /notifications/all/read`. Auth is an API key plus a token.

Fits `[.markDone, .remoteTruth]` cleanly, groups by board under the
auto-grouping we just shipped, and is the most indie-common tool on this list.
Trap: **the key and token go in the query string**, not a header — fine for
the Keychain, but URLs must never reach a log or a `ProblemLog` line.

### PagerDuty — verified, with two gates

**Verified from PagerDuty's own OpenAPI document:**
`GET /incidents` takes `user_ids[]`, `statuses[]`, `urgencies[]`,
`service_ids[]`, `since`/`until` and `sort_by` — so "assigned to me, still
triggered or acknowledged" is one call. It returns `{incidents: […]}` with
pagination carrying `offset`, `limit`, `total` and **`more`**, which is a
free, honest `snapshotWasComplete()`. `PUT /incidents` acknowledges,
resolves, escalates or reassigns up to 250 at once, so write-back is real and
maps to both verbs: `E` → acknowledge, `C` → resolve.

Two gates, both worth knowing before writing a line:

- **`PUT` requires a `From:` header carrying a valid user's email address**
  (required in the spec). So the source editor needs the email as a second
  field, or every write-back 400s.
- **A personal REST API key needs "Advanced Permissions" on the account**; a
  general-access key can only be made by an admin or account owner. On a
  personal account that is fine. On an employer's, it is the same
  admin-approval shape as Slack's install gate.

Also verified: **`GET /notifications` is not an inbox.** It is a log of
notifications *delivered* to you (sms, email, push) over a time range, so the
incident list is the right queue.

### Jira — good, and an approximation on purpose

**Verified from Atlassian's OpenAPI spec (421 paths):**

- **There is no notification-inbox endpoint.** The only `notification*` paths
  are `notificationscheme` admin config — who gets *emailed* — which is not a
  feed. So Jira is an assigned-work mirror, like Notion's ⚠️ verdict but
  sharper, because JQL is precise where Notion's search is not.
- **`GET/POST /rest/api/3/search` are both deprecated** — the spec says
  "Endpoint is currently being removed" (CHANGE-2046). The replacement is
  `/rest/api/3/search/jql`, whose response carries `issues`, `nextPageToken`
  and **`isLast`** — another free `snapshotWasComplete()`. Anything written
  against the old endpoint would be dead on arrival, which is the sort of
  thing worth knowing before starting.
- **`basicAuth` is supported**, so it stays paste-a-token: email plus an
  Atlassian API token.

The queue would be `assignee = currentUser() AND statusCategory != Done`,
plus optionally watched issues updated recently. **Mentions cannot be
enumerated** — JQL has no "mentioned me" operator — so a Jira comment
@-mentioning Brandon reaches him by email and not here, which the `sourceNote`
must say out loud. Write-back: there is no read-state to write, so `E` is
local and `.remoteTruth` does the real work (an issue resolved or reassigned
leaves the JQL result and auto-archives).

### Asana and ClickUp — to-do sources, not notification sources

**Verified for Asana:** its OpenAPI document has **no** `/notifications` or
`/inbox` path. Asana's Inbox is not in the API. What exists is `/tasks`
(filterable by assignee and workspace), `/user_task_lists/{gid}/tasks` — "My
Tasks" — `/tasks/{gid}/stories` for one task's comments, and `/events`, which
needs a resource to watch. Personal access tokens are supported.

So Asana declares **`completesTask` and not `markDone`**, exactly like
Reminders and Todoist: `E` dismisses locally, `C` completes in Asana. It
should go through `Connectors/Todo/`'s existing seam, and if `TodoItemMapper`
needs changing to fit, that is a signal the change belongs in the provider.
ClickUp looks like the same shape and is unverified.

### Stripe — the indie-solopreneur queue

**Verified:** `GET /v1/events` lists events **going back 30 days only**,
filterable by `type` or up to 20 `types[]`, with the array under **`data`**
and a `has_more` flag; `limit` is 1–100 with `starting_after` cursoring.

The utility is specific and real: a failed subscription payment, a dispute
(which has a deadline), a failed payout. For anyone running a paid product
this is the highest-consequence queue on the list. There is no per-event read
state, so `E` is local — and that is fine, because an event's `created` never
moves, so a dismissed row cannot resurrect.

### Help Scout, Front, Zendesk — the support desk

**Verified for Help Scout:** there is **no personal API key**. You create an
OAuth2 app from *Your Profile → My apps*, then use the `client_credentials`
grant to get a token that lasts **48 hours** (`expires_in: 172800`), and
credentials must belong to an active user on the account.

That makes it the only candidate needing a **refresh path** — the exact thing
§6.9 rejected Linear's OAuth for. It is still paste-a-token in feel (two
values into the Keychain, the app exchanges them silently), but it is more
machinery than everything above it. Front and Zendesk are plausibly cheaper
here and are unverified.

### incident.io — the Campsite shape

API keys are created **in the account dashboard with chosen scopes**, not
per-user in a profile, and are Bearer tokens. That is org-level auth on
someone else's account — the same shape that got Campsite removed (§6.5).
Worth building only if Brandon can mint his own key on Buffer's account; the
endpoint details are unverified.

## 3. Ruled out, with the reason

- **Discord — ToS, not technical.** Automating a *user* account outside the
  OAuth2/bot API is forbidden and risks account termination; a *bot* account
  cannot see your mentions or DMs. So a "my Discord mentions" connector
  cannot be built legitimately. Verified against Discord's own support and
  developer terms.
- **Google Calendar's API, and Gmail — same OAuth wall.** §6.13's verdict
  stands. Use EventKit and Mail.app respectively; both sidestep it locally.
- **Notion — already ⚠️ in §6.3**, build-on-demand, needs the deferred relay.
  Nothing has changed.
- **Figma — no cross-file mention feed is documented.** Comments are
  per-file, so a connector would have to be told which files to watch. The
  absence is inferred from shallow docs rather than proven, but the shape is
  wrong regardless.
- **Datadog, Better Stack, Grafana, Uptime Kuma, Cronitor** — all send
  webhooks, so **`ntfy` already covers them** and a connector would add
  nothing. Datadog is the best of these because it lets you *shape* the
  webhook payload, which is what makes a readable row.

## 4. What this changes about the escape hatches

**One caveat found while checking them.** A raw SaaS webhook posted to an
ntfy topic arrives as a wall of JSON, because ntfy takes the request body as
the message and no SaaS sets `X-Title`. So "point its webhook at ntfy" really
means "point it at a 20-line Worker that shapes it first", unless the
provider lets you template the payload (Datadog does; Vercel and Stripe do
not). Worth saying plainly in `docs/setup-sources.md`, since the current
framing oversells it.

## 5. The one change that beats three connectors

**`jsonPoller` accepts only a bare JSON array or `{"items": […]}`** — checked
in `JSONPollerConnector`. Every API researched today nests its list under a
different key: Stripe `data`, PagerDuty `incidents`, Jira `issues`, Vercel
`deployments`, Asana `data`.

So adding one optional `root=` term to the mapping string —
`root=data,id=id,title=…` — turns `jsonPoller` into a read-only source for
**Stripe, PagerDuty, Vercel, Asana, incident.io and most of the ruled-out
tier**, with no new connector, no new auth, and no new settings screen.

**Built 2026-09-04**, and verified end to end against a live public API that
nests its list (`hn.algolia.com`, `root=hits`): three real items with correct
timestamps, and the same feed without `root=` refused while naming the keys it
actually sent. `JSONPollerConnector.rows(in:root:)` is pure and takes a dotted
path. GitLab and Trello both return bare arrays, so either can be tried
through `jsonPoller` today before committing to a connector.

## 6. Recommended order

1. ~~**`root=` in `jsonPoller`**~~ — **done 2026-09-04** (§5).
2. **GitLab** — the only true inbox mirror on the list, and CI failures with
   it.
3. **Trello** — a real notification feed with two-way read state.
4. **PagerDuty** — verified good; settle the personal-key gate first.
5. **Apple Calendar** — highest utility, but decide what a meeting row *is*
   before writing it.
6. **Jira** — worth it with the mention gap stated in the `sourceNote`.

Everything below that waits for a real need.

## 7. What I did not verify

- **Vercel, Netlify, Railway, Render, ClickUp, Front, Zendesk, RevenueCat and
  App Store Connect**: named from general knowledge, not checked against a
  spec today. Do not quote their specifics.
- **incident.io's endpoints and rate limits**: from search results, not from
  its primary docs.
- **Stripe restricted keys**: whether an `rk_` key can read `/v1/events` was
  not confirmed; the docs example uses a secret key.
- **Figma's lack of a cross-file mention feed**: inferred, not proven.
- **Nothing was called with a real token.** Every verdict here is documentary
  — and this repo's own rule is that a config or client which has never been
  fed to the real service is unverified however carefully it was written. The
  first hour of any of these should be one `curl` with a real token before a
  line of Swift.
