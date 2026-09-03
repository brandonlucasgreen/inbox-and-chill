# Auto-grouping — folding one source's rows by what they are about (design plan)

Status: **BUILT 2026-09-03**, on `feat/auto-grouping`, the same day it was
planned. All three decisions in §6 were taken as recommended (*"agree with
all your recommendations, build it"*). Two things were found by running it
and are corrected in place rather than tidied away: ntfy rows already in the
queue *did* pick up keys on the first reconnect (§8 had said they would stay
loose), and `SourceRow` was already the name of the Sources-pane row view, so
the section-line enum is `SectionRow`. §10 records what was verified and what
still needs eyes. Asked for by Brandon:

> there already is a manual group feature, but it requires me to determine
> what notification should be grouped. We should build a system to
> automatically group notifications by distinguishing topic. this would vary
> by channel: for Slack, you can group by channel, for linear by issue ID or
> project slug, for NTFY by channel, etc. This should be an optional setting
> for each channel as well, so we use or can turn off auto grouping if they
> want to.

Everything under **Measured** was read out of a read-only copy of the live
store on this Mac on 2026-09-03 (`store.sqlite` + `-wal`, 3,388 items, 4
topics). Everything else is design. Three decisions are marked **DECISION**
and carry a recommendation; §10 lists what stays unverified until it is built.

This is the step the Topics plan deferred (`docs/topic-grouping-plan.md`
§12 step 7: *"nothing groups itself without being asked"*). The per-source
toggle is the asking.

---

## 1. Measured: what each key would collapse

One candidate key per source, applied to the last 7 days by `occurredAt`.
"Rows after" is what the section would show with every group of two or more
folded to one row.

| Source | Items | Key | Groups (≥2) | Rows after | Biggest |
|---|---|---|---|---|---|
| Slack | 188 | channel id (payload) | 29 | **49** | one channel × 19 |
| Linear | 298 | issue key, else project slug | 22 | 247 | a project × 7, `CORE-7227` × 6 |
| GitHub | 35 | repository | 4 | **6** | `brandonlucasgreen/unstream` × 27 |
| Apple Mail | 334 | sender | 57 | 162 | Bandcamp × 24 |
| Apple Mail | 334 | conversation (subject minus Re:/Fwd:) | 41 | 271 | a Datadog digest |
| ntfy | 41 | topic | 2 | **3** | `uptime-kuma` × 34 |
| Reminders | 99 | list | 4 | 7 | Reminders × 42 |
| Claude Code | 31 | — | 0 | 31 | (nothing to key on) |

Over 30 days the shape is the same and sharper: GitHub 458 → 11 rows
(`bufferapp/buffer-android` alone is 328), Slack 480 → 91, Linear 576 → 386
(`EPD-1873` × 27 is the biggest single key).

Five things fall out of this, and each one decides something below:

- **Slack, GitHub and ntfy are where the pile-up is.** 455 of 480 Slack rows
  are keyword-watch hits, and a watched term fires many times in the same
  channel. GitHub notifications are already one row per thread, so the only
  grouping left is the repository — and it is a very good one.
- **Linear is finer-grained than it looks.** 468 of 576 rows carry an issue
  key and 77 a project; grouping by issue folds only a sixth of them. It is
  still worth doing (an issue with six notifications is exactly the row you
  want to see once), but the big collapse Slack gets is not on offer here
  unless everything groups by *project*, which is a different feature (§9).
- **Mail groups better by sender than by conversation** — 229 items in
  groups against 104. The senders are newsletters, bots and digests, which is
  the mail that should fold.
- **To-do sources fold too well.** 18 active reminders across 4 lists would
  become 4 rows and a badge of 4. A to-do is not a notification (CLAUDE.md,
  "A to-do is not a notification"); folding tasks behind a list name hides
  work rather than noise. Offered, default **off** (§6).
- **Claude Code has nothing to group by.** The hook does not record the
  project directory, and a session is already one row. Not offered; §9 has
  the follow-up.

## 2. What an auto group is — and is not

An auto group is **a view-layer fold, not a Topic row.** The connector labels
each item with the thing it is about; the panel folds a source section's rows
that share a label, when that source's toggle is on. Nothing is created in
the store, nothing is named, and nothing has to be purged.

Concretely, two optional strings on `Item`, refreshed on every poll like
`kind` and `title` — the *opposite* of `topicID`:

```swift
/// What this item is about within its source — the Slack channel id, the
/// Linear issue key, the repository, the ntfy topic. Source-authoritative
/// and refreshed by `Store.update`, unlike `topicID`, which is yours.
var groupKey: String?
/// How that key reads: "#deploys", "EPD-1873", "owner/repo".
var groupLabel: String?
```

and the same two on `RemoteItem`, filled by each connector's pure item
builder (§3).

### Why not reuse the Topic row

The first draft of this plan created a `Topic` per key (`groupKey` on
`Topic`, find-or-create at insert, assign `topicID`). It was cut for four
reasons, and the reasons are worth keeping:

- **Every problem the Topics plan had to solve returns.** Empty groups as a
  resting state, purge rules, a naming card, back-fill when a toggle flips,
  and a `Topic` row that exists for a channel the user muted a month ago.
- **Toggling has to be instant and lossless.** Turning grouping off and on
  again must give back exactly the queue you had. A fold computed from
  `groupKey` does that for free; membership written into `topicID` needs a
  back-fill pass in both directions and a rule for members the user moved.
- **A topic is yours; a group is the source's.** `topicID` is deliberately
  left out of `Store.update` so a poll cannot dissolve what you built. A
  channel label is the reverse — the source is authoritative, so it belongs
  *in* `update`, where a channel rename fixes itself on the next poll. Putting
  both in one field means one of them is wrong.
- **The invariant stays one line.** "Explicit beats rule" is `item.topicID
  != nil` → not auto-grouped. A member you file into a topic with `G` leaves
  its channel group and stays left; there is no second membership to
  reconcile.

The cost is that a group has no identity to hang state on: no renaming, no
per-group ungroup, no "always fold this channel but never that one." None of
that was asked for, and `G` on a group header (§5) is the path to a real
Topic when a group turns out to matter.

## 3. What each connector labels — one pure function each

| Kind | `groupKey` | `groupLabel` | Where it already is |
|---|---|---|---|
| `slack` | channel id (`C096W5L93V2`) | `#deploys` | `payload.channel`; the name from `channelName()` / `match.channel.name` |
| `linear` | `issue:EPD-1873`, else `project:<slug>` | `EPD-1873 · <issue title>`, else project name | `node.issue.identifier`, `node.project.name` / `.url` |
| `github` | `owner/repo` | `owner/repo` | `thread.repository.full_name` (already the snippet) |
| `sentry` | project slug | project slug | `issue.project.slug` (already the actor) |
| `ntfy` | topic | topic | `frame.topic` (already the actor) |
| `appleMail` | sender address, lowercased | sender display name | `sender` field; `displayName(fromSender:)` |
| `reminders` / `todoist` | list / project id | list / project name | `TodoTask.listName` |
| `local`, `jsonPoller`, `fake` | nil | nil | not offered (§9) |

Rules that hold across all of them:

- **The key is the stable id, the label is the human name.** A channel rename
  changes the label and not the key; the fold survives and the header
  updates on the next poll.
- **No key for a row that is already the group.** A Slack DM is
  `dm-<channelID>` — one row per conversation by construction — so it gets
  no key. A key that only ever has one member costs a comparison and buys
  nothing.
- **Slack DMs and unknown channels never fold.** `channelName()` and
  keyword-watch both fall back to the raw channel id when there is no name,
  and `isRawChannelID` already says which those are. A group labelled
  `C0AP7Q92ZPB` is worse than nineteen rows.
- **Linear: issue first, project as the fallback** for the notification types
  that have no issue (project updates, documents, initiatives). A comment on
  `EPD-1873` and a status change on `EPD-1873` are one thing; two issues in
  the same project are two.
- **Mail keys on the address, not the display name.** "Bandcamp" and
  "Bandcamp <noreply@bandcamp.com>" are one sender; two people called Sam are
  not.

Every one of these lives in a builder that is already `nonisolated static`
and tested (`SlackSearch.watchHit`, `LinearConnector.mapItem`,
`NtfyConnector.item(from:)`, `SentryConnector.item(from:)`,
`AppleMailConnector.item(fromRecord:)`, `TodoItemMapper`), so each is two
lines and two assertions.

## 4. Where a group lands in the panel

**Inside its source section.** This is the design decision that makes auto
groups different from Topics, and it follows from the groups being
single-source:

- The TOPICS section exists because a topic *spans* sources. Putting
  `#deploys` there would move every Slack row out of SLACK and into TOPICS,
  and the by-source organisation the panel is built on would empty itself.
- **A source filter must not dissolve an auto group.** Scoping to Slack with
  `→` means "show me Slack", and "Slack, folded by channel" is the answer.
  Topics dissolve under a source filter because a cross-source row is not an
  answer to that question; a same-source fold is.
- The header's source chips — the one fact a collapsed topic has that a row
  does not — say nothing here. The header shows the **label** instead.

```
│  SLACK                                     49 │
│    ▸ #deploys                          19  2m │
│      “inbox” in #deploys · Sam: the new…       │
│    ▸ #eng-ios                          18  9m │
│      “inbox” in #eng-ios · CI is red on…       │
│      Sam mentioned you in #general         1h │   ← a loose row: one member
│  LINEAR                                     5 │
│    ▸ EPD-1873 · Route feedback to FeatureOS 3 │
│      Commented: Ana: can we ship this beh…     │
│      Assigned: CORE-7301 Rate limit the…   3h │
```

Within a section, groups and loose rows are **one list sorted by newest**,
so a group with a fresh member rises past an older loose row exactly as the
row itself would have. Open (`D`), members render indented under the header,
newest first, as ordinary `ItemRowView`s — every verb, hover action and
context menu unchanged, which is the whole reason members are ordinary rows.

**The second line is the newest member's title.** A header that says only
`#deploys` tells you where, not what; the notification-centre idiom is to
show the latest item under the stack. This is the one visual judgement in
the plan that needs eyes rather than argument (§10).

Everything else reuses `TopicGroup` and `TopicRowView` as they are, with a
`kind` distinguishing a topic from a fold: no source chips, the label as the
name, the preview line, and no "Edit Topic" in the context menu.

Three rules carried over from Topics unchanged, because they were right:

- **Below `TopicPolicy.minimumVisibleMembers` (2) a group is a row.** A
  triangle over one thing is a lie. Unlike a topic, a one-member group draws
  **no chip** — "In a topic" means *you filed this*, and nothing here was.
- **A grouped row renders nowhere else.** One row per thing.
- **Pinned and snoozed rows stay loose.** Pinning is per item and PINNED is a
  flat section; `⌘P` on a header pins the members and they move there as
  rows. Same for `S`. Grouping the Pinned and Snoozed sections is possible
  and not worth it until someone misses it.

## 5. Keyboard — nothing new to learn

`PanelQueue` splices member uids after an open header exactly as it does for
topics, so `↑`/`↓` walk in and out, `openTopicID` holds the open group's row
id (`QueueRowID.group("<sourceID>:<key>")`), a group closes when the
selection leaves it, and `Esc` peels it as one more layer. `D` is a level, as
before.

| Key | On a group header |
|---|---|
| `D`, `⏎`, double-click | open / close members |
| `E`, `S`, `U`, `C`, `⌘P` | act on every member — one undo entry, one save (`Store.markDone(uids:)` etc. already exist) |
| `G` | mark the members and open the naming card — **the path from a fold to a Topic** |
| `⌘⏎` | refuse out loud, same sentence a topic uses |
| Space, ⌘-click | mark every member (so `E` on a mixed selection keeps working) |

`C` keeps its all-or-nothing rule and its refusal (`canCompleteAll`), which
matters more here than for topics: a to-do list group is exactly the case
where every member can be completed.

## 6. The toggle

**Per source, in the Sources pane row, beside On / Badge / Banners.** That
row is already the home of "how does this source behave in the queue"
(`countsTowardBadge`, `bannersEnabled`), and a fourth checkbox reads as one
more of those. It is *not* a connector setting: the connector labels every
item regardless, and only the fold is optional — so it does not belong in
the source editor with the token fields, and `ConnectorFactory` never sees
it.

```swift
// SourceConfig
/// Fold this source's rows by `Item.groupKey`. nil means "the kind's
/// default" — see `ConnectorKindDescriptor.grouping`.
var autoGroups: Bool?

// ConnectorKindDescriptor
struct Grouping: Sendable {
    var noun: String        // "channel", "issue", "repository", "sender", "list"
    var defaultOn: Bool
}
var grouping: Grouping?     // nil: the checkbox is not offered for this kind
```

- **`Bool?`, not `Bool`.** An absent value means the kind's default, exactly
  as `Field.boolValue(in:)` treats an unwritten toggle. It also sidesteps
  the migration question: no existing `SourceConfig` row has to be given a
  value, and reminders comes in as "default off" without a data fix.
- **Checkbox label "Group", help "Fold rows by \(noun)."** One sentence, one
  place; the noun is the only thing that varies per kind (one fact, one
  home).
- **Not offered where there is no key** — `local`, `jsonPoller`, `fake`. A
  checkbox that does nothing is the copy-volume problem in another shape.

**DECISION 1 — defaults.** Recommendation: **on** for Slack, Linear, GitHub,
Sentry, ntfy and Mail; **off** for Reminders and Todoist. The measurement
says the six fold noise and the two fold work. The narrow-rollout rule
argues for shipping everything off and letting Brandon turn sources on one
at a time; against that, he asked for the feature in the form "on, with a
way to turn it off", and the toggle is what makes the rollout narrow. Either
way it is one Bool per descriptor.

**DECISION 2 — Mail's key.** Recommendation: **sender.** 229 of 334 items
fold against 104 for conversation, and the senders that fold are the
digests and bots. Conversation grouping is what Topics already do by hand
for the mail that matters.

**DECISION 3 — Linear's key.** Recommendation: **issue first, project as
fallback**, as measured. Grouping everything by project would fold harder
(a project with 22 notifications becomes one row) but would put two
unrelated issues under one header, and a status change on your issue would
hide behind the project name. If issue grouping feels too fine in the hand,
"by project" is a second `Grouping` variant for one kind — a follow-up, not a
rewrite.

## 7. The badge counts a group as one

`Store.badgeCounts` already counts a topic as one (Brandon's call,
2026-08-26: *a badge reading 54 while the queue shows one row makes the
queue the liar*). The same sentence applies here, so it gains the set of
grouping source ids and counts, per source: loose active rows, plus distinct
`groupKey`s. A one-member group counts one either way, so the visible
threshold does not leak into the count.

Expect the number to drop hard on the first launch — Slack from 188 to 49 in
last week's shape. That is the feature working, and it is the thing to check
first if the badge "looks wrong" after install.

## 8. Traps

- **`groupKey` and `groupLabel` go *into* `Store.update`.** The opposite
  rule from `topicID`, for the opposite reason, and a test asserting each
  (`updateLeavesMembershipAlone` already guards one side; add
  `updateRefreshesGroupKey` beside it). Rows written by 0.5.0 have no key
  until their next poll. Polling sources refreshed within a minute of the
  first launch (84 rows keyed in 20 seconds), and ntfy's reconnect replayed
  its recent messages so those keyed too; `local` rows never will, and have
  no key to gain.
- **Slack's channel name is async.** `channelName()` hits
  `conversations.info` on a miss. The builders already await it for the
  title, so the label costs nothing extra — but keyword-watch has the name
  in the search response and must use that, not a second lookup per hit.
- **Never let `marks.uids` into `PanelView.body`.** Marking every member on
  `Space` over a header goes through `PanelMarks`, same as ⇧↓, or the
  full-panel re-render returns (CLAUDE.md, "Marking has to be cheap").
- **Banners are unchanged and will still fire per item.** Nineteen keyword
  hits from one channel in a minute are nineteen banners today and
  tomorrow. Coalescing banners per group is a separate, smaller feature
  (§9); do not fold it in here, because it changes what "new item" means
  for `announcesReturn` and the journal.
- **The main window stays flat.** It lists items individually and does not
  render Topics either; grouping a `Table` is a different design. Its `⌘G`
  and `TriageActions` need nothing.
- **Text filter shows matching members, opened**, as for topics — typing
  `deploys` should land on the group, not on a header that hides the hit.
- **`PanelQueue` is pure and stays pure.** The toggle arrives as a
  `Set<String>` of grouping source ids computed once in `PanelView` from
  `configs` and the catalog, not as a per-item catalog lookup inside the
  fold.

## 9. Deliberately not in this plan

- **Claude Code sessions by project.** Needs `cwd` in
  `LocalListener.SessionOrigin`, written by `inchill claude-hook` — a hook
  change with an upgrade path (`ClaudeCodeIntegration.outdated`), so its own
  PR. Worth doing: 31 session rows a week is real.
- **Custom JSON feeds.** A `group=<field>` entry in the mapping string is
  ten lines and obvious; nobody has asked.
- **Banner coalescing per group** (§8).
- **Grouping Pinned, Snoozed, the archive, or the main window** (§4, §8).
- **A second key per kind** (Linear by project, Mail by conversation) as a
  per-source choice. The `Grouping` shape leaves room; the toggle does not
  need it yet.
- **Muting a group from its header.** Slack already has Mute Channels in its
  settings; a "Mute #deploys" context-menu item that writes to it is a
  natural next verb, and a different feature.

## 10. Tests and verification

**Verified 2026-09-03, after the build:**

- **543 tests pass**, including `PanelFoldLayoutTests` (11), the two store
  tests that guard `Store.update`'s opposite rules for `groupKey` and
  `topicID`, the badge test, and a key/label assertion in every connector's
  builder test (Slack, Linear, Sentry, ntfy, Mail, to-do).
- **The SwiftData migration, against the real store**: support directory
  backed up to `InboxAndChill.backup-pre-autogroup-191150`, Release build
  installed via `install-local.sh`, **3,395 `ZITEM` rows before and after**,
  `ZGROUPKEY`/`ZGROUPLABEL` added to `ZITEM`, `ZAUTOGROUPS` to
  `ZSOURCECONFIG`, no error in the app's log.
- **The change is in the installed binary**: two `strings` hits each for
  `Make a topic of these` and `Turn it off to see every row on its own`.
- **Live rows key correctly**: within a minute, Linear rows read
  `issue:CORE-7448` / `project:<url>`, Mail rows keyed on the address with
  the display name as label, ntfy on `uptime-kuma`, Reminders on the list
  (keyed but not folded — default off). Slack had one active row, so no fold
  was observable at install time.

**Not verified, and Brandon's to judge:** nothing has been rendered or
pressed — no Screen Recording or Accessibility here. Whether a fold header's
second line earns its height, whether the by-date interleave reads as one
list, and whether "Group" beside On / Badge / Banners is findable are the
three hand-feel calls, each one line to change.

Pure, no store, no network — insert mid-file, parallel sessions:

Pure, no store, no network — insert mid-file, parallel sessions:

- Each connector builder emits the key and label in §3, and **does not** for
  a Slack DM, a raw channel id, a Linear notification with neither issue nor
  project, and a mail record with an empty sender.
- `PanelQueue`: groups fold inside their source section and nowhere else;
  a member with a `topicID` is left to its topic; one member renders as a
  plain row with no chip; a source filter keeps groups; the toggle off gives
  back the loose rows in the same order; `visibleUIDs` splices an open
  group's members after its header; a text filter opens the matching
  members.
- `Store.update` refreshes `groupKey`/`groupLabel`; `Store.update` still
  leaves `topicID` alone.
- `badgeCounts` counts a group as one and a one-member group as one.
- Descriptor: every kind with `grouping != nil` has a connector test that
  emits a key — a static list and a grep, so a new kind cannot offer a
  checkbox that does nothing.

Then rule 1: back up the support directory, install, confirm the
SwiftData migration (two optional attributes on `Item`, one on
`SourceConfig` — the same shape `topicID` was, verified by row count before
and after), `strings` for a marker longer than 15 ASCII bytes and unique to
the new code, open the panel and watch Slack fold.

**What a machine cannot verify, and Brandon has to:** whether the header's
second line (newest member) earns its height in a 420pt panel; whether
groups sorted by newest member interleaved with loose rows reads as one
list or as jitter; and whether "Group" beside On / Badge / Banners is
findable. All three are one-line changes if they grate.

## 11. Order of work

1. `RemoteItem` + `Item` fields, `Store.update`, the two tests; migration
   check against a backed-up copy.
2. Connector labels (§3), one commit per connector, tests with each.
3. `SourceConfig.autoGroups`, `ConnectorKindDescriptor.grouping`, the
   Sources-pane checkbox.
4. `PanelQueue`: fold inside `SourceGroup`, `QueueRowID.group`, splicing,
   filter behaviour — tests before the view.
5. `TopicRowView` fold variant + `PanelView` wiring (`D`, verbs, `G`).
6. `badgeCounts`.
7. CLAUDE.md: a short section under Topics — a new per-item field refreshed
   by `update` is exactly the kind of fact that file exists to record.

Steps 1–5 are the feature. 6 is what stops the badge lying about it.
