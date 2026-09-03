# Topics — grouping one thing across sources (design plan)

Status: **BUILT 2026-08-26**, on `claude/notification-grouping-design-cd1bab`.
All three decisions in §5, §8 and §9 were taken as recommended
(*"Agree with all your recommendations on paper. Let's build this as you
propose"*). Two things changed during the build and are corrected in place
rather than tidied away: link tokens are read out of an item's whole text and
not just its `url` field (§6, found by a failing test — the shared-link case is
asymmetric by nature), and `G` on a topic header edits that topic rather than
refusing. The migration in §11 has now been **run against the real store**:
2,234 rows before and after. Asked for 2026-08-26 by Brandon:

> I sometimes get an email, linear update, multiple slack messages, and a
> reminder all about the same topic. It would be great to be able to group
> these together (maybe via a multi-select operation) and then see the group
> in the menubar inbox. To see the individual messages, I could type the D key
> to expand to each instance (which I could in turn hit D again to see context
> on each).

Everything under **Measured** was read out of the live store on this Mac on
2026-08-26 (a read-only copy of `store.sqlite` + `-wal`, 2,223 items with a
timestamp). Everything else is design, and §11 lists what is still unverified.

Three decisions were open and are marked **DECISION** below. All three were
taken as recommended on 2026-08-26 and are kept as written, because the
reasoning is what a future reader will want, not the verdict on its own.

---

## 1. Measured: this happens, and it has a shape

**Every working day since GitHub and Linear were both live has had at least
one topic spanning two or more sources.**

| Day | Items | Cross-source topics |
|---|---|---|
| 08-19 | 154 | 1 |
| 08-20 | 206 | 4 |
| 08-21 | 66 | 2 |
| 08-22/23 | 19 / 23 | 0 (weekend) |
| 08-24 | 81 | 1 |
| 08-25 | 101 | 1 |
| 08-26 | 77 | 2 |

Across the whole store: **14 topics span more than one source kind, and they
cover 118 items.** The biggest, `EPD-1873`, has **54 occurrences across four
sources** — Linear, GitHub, Apple Mail and Claude Code. That is 54 rows that
want to be one row.

Four facts fell out of the same pass, and each one decides something below:

- **An issue key is the identifier that actually crosses sources.**
  `[A-Z]{2,6}-\d+` appears in Linear titles, GitHub titles, Mail subjects and
  Claude Code session snippets. 461 distinct keys in the store.
- **A bare `#1234` is not.** It produced a false positive immediately —
  `#116` matched a `fake` row and a Linear row that have nothing to do with
  each other. Only a repo-qualified `owner/repo#123` is safe.
- **Mail joins on its own about half the time**: 21 of 50 mail items carry an
  issue key.
- **Reminders never do. 0 of 22.** They all carry a URL and no key. This is
  the load-bearing one: in Brandon's own example the reminder is a member, and
  **no auto-matcher will ever find it.** Manual membership is therefore not a
  convenience on top of auto-catch — it is the primitive, and auto-catch is
  the thing layered on top.

## 2. What a Topic is

A **Topic** owns exactly two things: a **name** and an optional **rule**.
Every other question about it is answered by its members.

```swift
@Model final class Topic {
    @Attribute(.unique) var id: String     // UUID string
    var name: String
    var createdAt: Date
    /// Auto-catch terms. A new item matching any of these joins.
    var terms: [String]
}
```

and on `Item`:

```swift
/// The topic this item belongs to, or nil. Local state, like `pinnedAt`
/// and `seenAt` — never touched by `Store.update(_:from:)`.
var topicID: String?
```

**Derived, not stored:** active / snoozed / done / pinned / high-signal /
seen. A topic is active when it has active members; it is pinned when its
members are; it disappears from the queue when they are all done. There is no
second state machine to keep in sync with the first, and every rule the queue
already has keeps working unchanged.

Two consequences worth stating:

- **A Topic outlives its members.** All four members auto-archive, the topic
  renders nowhere — and then a new `EPD-1873` item arrives next morning and
  the topic re-forms with it. That only works if the `Topic` row persists
  while empty. It is purged on the same 90-day rule as items: no member
  touched in 90 days, the topic goes with them.
- **A one-member topic renders as an ordinary row**, with a small topic chip
  instead of a disclosure triangle. A triangle you open to find one thing is a
  lie, and `.remoteTruth` will erode topics to one member routinely.
  `Topic.minimumVisibleMembers = 2`, in one place.

### Why a `String?` and not a SwiftData relationship

Every cross-entity link in this app is already a string id — `sourceID`,
`uid`, `Keychain`'s `<UUID>.<field>`. `Store` fetches by uid and nothing holds
an object graph. A real relationship would need an inverse, would put cascade
semantics into `purge()` (which today just deletes rows), and would make
`reconcile()` fault in Topic objects per source. The string keeps the actor
boundary exactly where it is.

## 3. Where it lands in the panel

The queue's top-level organisation is *by source*, with sticky headers. A
topic spans sources, so it cannot live inside one of them. It gets its own
section, between Pinned and the source sections:

```
┌─ filter bar ──────────────────────────────────┐
│  PINNED                              2        │
│  TOPICS                              2        │
│    ▸ EPD-1873 — route feedback to FeatureOS   │
│      ◇linear ◇github ◇mail ◇reminders   4  2m │
│    ▸ CORE-7130 — stale upload error notices   │
│      ◇linear ◇slack                     2  1h │
│  SLACK                               3        │
│  LINEAR                              1        │
│  SNOOZED                             4        │
└───────────────────────────────────────────────┘
```

Open (D on the topic row):

```
│    ▾ EPD-1873 — route feedback to FeatureOS   │
│      ◇linear ◇github ◇mail ◇reminders   4  2m │
│        ◇ Checks failed: feat(core-api)…    2m │
│        ◇ State changed: feat(core-api)…    9m │
│        ✉ Re: EPD-1873 deploy window        1h │
│        ☑ Ship EPD-1873 behind a flag       3h │
```

Member rows are ordinary `ItemRowView`s, indented, with the source glyph doing
the job the missing section header would have done. **Every triage verb, hover
action and context menu on a member works exactly as it does today** — that is
the point of making members ordinary rows rather than a bespoke sub-view.

Members are **removed from their source sections** while they belong to a
topic. One row per thing, everywhere; a mention that appears both under SLACK
and inside a topic is the pile-up this feature exists to remove.

Two interactions with what is already there:

- **A source filter dissolves topics.** Scoping to Slack means "show me
  Slack", so the topic's Slack member appears as a plain row under SLACK and
  the topic header does not render. `PanelQueue` already scopes before it
  groups, so this is where the code naturally falls anyway.
- **The text filter keeps a topic when its name or any member matches**, and
  shows only the matching members, opened. Typing `EPD-1873` should land on
  the topic, not on four scattered rows.

## 4. Keyboard — D is a level, not a toggle

Today the panel has two expansion states and one flag (`isFullyExpanded`),
and `select(_:)` resets it so only one row can ever be open. Topics add a
level, so that becomes two flags:

| Flag | Meaning | Invariant |
|---|---|---|
| `openTopicID: String?` | which topic shows its members | at most one |
| `isFullyExpanded: Bool` | which row shows its whole message | at most one |

- `D` on a **topic row** → open/close its members.
- `D` on a **member** → whole message + `RowContextView`. Exactly today's
  behaviour, unchanged.
- `↑`/`↓` walk into and out of an open topic: member uids are spliced into
  `visibleUIDs` immediately after their topic row, so traversal stays "exactly
  what is on screen, top to bottom" — the property `PanelQueue` already
  promises.
- **A topic closes when the selection leaves it.** Same discipline as
  `isFullyExpanded`: the panel's job is to fit the queue on one screen, and
  leaving a trail of open topics behind you defeats that. Arrowing back up
  re-enters the closed topic row. (Alternative — keep it open until D closes
  it — is one line, if it feels wrong in the hand.)
- `Esc` peels one layer: full member → members closed → filter → archive →
  dismiss. It already reads as a stack; this adds one frame to it.

### Verbs on a topic row

| Key | On a topic |
|---|---|
| `E` | dismiss **every active member**, one undo entry |
| `S` | snooze every active member to the same time |
| `⌘P` | pin/unpin every member |
| `C` | complete every member — **only if every one can**, reusing the existing `canCompleteAll`; otherwise refuse out loud |
| `⏎` | open the topic (same as D) — a topic has no URL |
| `⌘⏎` | refuses out loud: "A topic has no single link. Open a member with ⏎." |

`C`'s all-or-nothing rule and its `openProblem` refusal already exist for
single rows (`AppState.completeTask`, `canCompleteAll`). Topics reuse both
rather than inventing a second answer to "can this be completed".

`E` on a topic is the whole payoff. If it dismissed only the header and left
four rows behind, there would be no reason to build any of this.

## 5. Creating a topic

**DECISION 1 — where the multi-select gesture lives.**

The main window already has real multi-select (`Table(selection:)` over
`Set<PersistentIdentifier>`, plumbed to the menu bar through `TriageActions`),
so it gets `⌘G` "Group into Topic…" nearly for free. The panel has none: it is
single-selection, keyboard-first, 420pt wide.

**Recommendation: add a mark-set to the panel as well, and make the panel the
primary place.** Grouping is a triage act, triage happens in the panel, and a
feature that requires opening a window will not get used.

- `Space` toggles a **mark** on the selected row — a filled checkbox where the
  unseen dot sits. Marks are a `Set<String>` in `PanelView` state, nothing
  persisted.
- `G` groups every marked row (or, with no marks, just the selected row) and
  opens the naming sheet.
- Marks are read by `G` alone. Every other verb still acts on the selection,
  so nothing about triage changes and there is no "which one does E use?"
  ambiguity.

  **Superseded 2026-08-27.** Brandon, the day after first use: *"now that we
  have a way of multi-selecting notifications - bulk actions. I should be able
  to select multiple notifications, and not only group them, but also dismiss
  them all with the E key, or mark them read/unread with U."* `E`, `S`, `U`,
  `C` and `⌘P` now act on the marks too. The objection above was sound about
  the build it was written for — marking had no affordance then — and expired
  the moment marking became visible. The rule that replaced it: the mouse acts
  on what it points at, the keyboard acts on what is marked.

Verified against the key handler: `Space` and `g` both currently fall into the
type-to-filter default, and both are safe to take behind the same
`filterText.isEmpty && !isFiltering` guard that `E`/`S`/`U`/`D`/`C` already
use — a leading space is meaningless to a filter that trims whitespace.

Cost: roughly a `Set<String>`, one checkbox in the dot column, two key cases,
and a sheet. It does not touch `PanelSelection`, the triage verbs, or
`PanelQueue`'s traversal order.

The alternative is main-window-only: cheaper by a sheet and a checkbox, and
almost certainly unused.

### The naming sheet

Name, pre-filled with the shared token when there is one (`EPD-1873 — route
feedback to FeatureOS`), plus **suggested catch terms** the selection has in
common, each a checkbox. Grouped form in a sheet, per the density preference.

## 6. Auto-catch — what keeps a topic true tomorrow

Manual grouping alone breaks by lunchtime: three more Slack messages arrive
about `EPD-1873` and land outside the topic he just made. Terms are what turn
"group these four" into "I am tracking this thing".

`TopicMatcher`, `nonisolated static`, pure, tested without a store (rule 6):

```swift
static func suggestedTerms(for items: [Item]) -> [String]
static func matches(_ terms: [String], title: String,
                    snippet: String?, url: String?) -> Bool
```

- Suggestions come from tokens present in **two or more** of the selected
  items: issue keys (`EPD-1873`), repo-qualified issue numbers
  (`buffer/core#1740`), and shared URL paths. **Never a bare `#1234`** — §1
  caught that producing a false match on real data.
- Matching is case-insensitive, on word boundaries, against title + snippet +
  URL. The boundary matters: `EPD-187` must not swallow `EPD-1873`.
- It runs in `Store.reconcile` / `Store.apply` at insert, so an item joins its
  topic before it is ever rendered, before a banner, and before the badge
  counts it. One place covers both poll and push.
- Cost is (topics × new items) substring searches. Topics are a handful.

A term matching an item **already in another topic** leaves it alone —
explicit membership beats a rule, always, and the rule cannot steal a row you
placed by hand.

## 7. Traps

- **`Store.update(_:from:)` must not touch `topicID`.** It refreshes nearly
  every field from the remote, and `kind` was recently *added* to it for good
  reasons. `topicID` is local state like `pinnedAt`, `seenAt` and
  `unreadHeldAt`. A test asserting a poll does not dissolve a topic is the
  single most valuable test in §10.
- **Batch the store write, not the write-through.** Four separate `markDone`
  calls mean four `save()`s and four `queueVersion` bumps, so a topic dismissal
  animates as four staggered collapses instead of one gesture — exactly what
  `PanelMotion` exists to prevent. `Store.markDone(uids:)` does one save. The
  *engine* calls stay per item: each source still has to be told individually.
- **`undoStack` has to become entry-shaped.** It is `[String]` today, and
  `restore` does `undoStack.removeAll { $0 == uid }`. A grouped dismissal is
  one ⌘Z, so it becomes `[[String]]` (or a small struct) and `restore` removes
  the uid from every entry and drops entries that empty out. `undoDone`
  already returns the `DoneReason` per uid, which a batch needs to keep doing —
  a completed to-do member must un-complete remotely while a dismissed Slack
  member must not.
- **A resurrected member keeps its topic**, which is right and needs no code —
  `resurrectIfNeeded` clears `doneAt` and nothing else.
- **Purge deletes items; something must tidy topics.** `purge()` gains a
  second pass for topics with no surviving member.
- **The archive still lists members individually.** Grouping the archive is a
  separate design and probably not worth it; say so rather than half-doing it.
- **Journal**: a grouped dismissal should write one line per member (the
  journal is a record of notifications, not of UI gestures) with the topic name
  in `detail`. Cheap, and it keeps `JournalWriter` untouched.

## 8. The badge

**DECISION 2 — does a topic count as 1 or as N?**

**Recommendation: 1.** The badge answers "how much is waiting", the feature's
premise is that four notifications about one thing are one thing, and a badge
that still says 54 makes the queue lie. A topic is high-signal if any active
member is.

Concretely `badgeCounts` becomes: active items with no topic, plus visible
topics. It is a one-line switch either way, so it can be tried and reversed.

## 9. Naming

**DECISION 3 — is "Topic" the word?**

"Group" is taken twice over: `SourceGroup` is the per-source section, and "All,
grouped by source" is how the panel already describes itself. "Thread" is taken
by Slack, and `ItemContext.messagesLabel` literally renders "Thread · #deploys"
inside the expanded row.

"Topic" is the plainest accurate word — and it collides with **ntfy topics**,
which appear in the ntfy source editor as a settings field and in its setup
steps. The collision is confined to one connector's settings and never appears
next to the queue's own section header.

**Recommendation: Topic**, and accept the ntfy overlap. If that grates, the
next-best is "Bundle".

## 10. Tests (pure, no store, no network)

- `TopicMatcher.suggestedTerms` against fixtures in the real shapes measured in
  §1 — `"Checks failed: feat(core-api): route in-product feedback … / EPD-1873"`
  — including the negative: a bare `#116` in two unrelated items suggests
  nothing.
- `TopicMatcher.matches`: word boundary (`EPD-187` ≠ `EPD-1873`), case, URL.
- `PanelQueue` with topics: section order; member uids spliced into
  `visibleUIDs` in the right place; a one-member topic degrades to a plain row;
  a source filter dissolves topics; a text filter keeps a topic when a member
  matches.
- `Store`: batch done writes once and undo restores exactly that batch;
  **a poll does not clear `topicID`**; purge tidies orphaned topics.

Insert them mid-file in `Tests/UnitTests.swift` and `Tests/TriageTests.swift`
rather than appending — parallel sessions.

## 11. Verification status (updated after the build)

**Verified:**

- **The SwiftData migration, against the real store.** Support directory
  backed up to `InboxAndChill.backup-pre-topics`, then the Release build
  installed and launched: **2,234 `ZITEM` rows before and after**, `ZTOPIC`
  created, `ZTOPICID` added to `ZITEM`, no migration error in the app's log.
  Adding a model and one optional attribute is indeed lightweight here.
- **515 tests pass**, including the eleven new suites in
  `Tests/TopicTests.swift`.
- **The change is in the installed binary** — two `strings` hits each for
  `Catch new items mentioning` and `Nothing to group. Mark rows with Space`
  (universal binary, so two is correct), and 0 for a control literal.
- The app launches and runs against the migrated store.

**Still unverified — and both are for Brandon rather than for a machine:**

- **Nothing has been rendered or pressed.** No Screen Recording or
  Accessibility here, so the panel has not been seen with a topic in it. The
  one overflow risk found by reading — four or more source chips on a 420pt
  row — is capped at three chips plus "+N", but the vertical weight of a topic
  header (name + chip row) is a judgement call that needs eyes.
- **Whether closing a topic on selection-exit feels right** is a hand-feel
  question. It is one line to change if it grates
  (`PanelView.select`).

## 12. Order of work

1. `Topic` model, `Item.topicID`, migration check against a backed-up copy.
2. `Store` verbs — create/rename/delete, add/remove members, batch done and
   snooze, entry-shaped undo. Tests first; they need no UI.
3. `PanelQueue`: the Topics section, member splicing, filter behaviour.
4. Panel rendering + `D` traversal + verbs on a topic row.
5. Creating: panel marks (`Space` / `G`) + the naming sheet; the main window's
   `⌘G` falls out of the same store verbs.
6. `TopicMatcher` + auto-catch at insert.
7. *(Later)* Suggested topics — "3 items mention EPD-1873. Group them?" — as an
   offer he confirms, never silently. Per the narrow-rollout rule, nothing
   groups itself without being asked.

Steps 1–5 are a usable feature on their own. Step 6 is what stops it going
stale by lunchtime, and the §1 measurements say it will pay for itself on six
days out of six.
