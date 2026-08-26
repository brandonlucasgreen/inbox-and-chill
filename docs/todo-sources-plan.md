# To-do sources — design plan (draft for PLAN.md §6.6)

Status: **built 2026-08-26** — the design below is what shipped in the same
branch, with §4's recurrence reasoning corrected mid-build by a spike (the
correction is kept in place rather than tidied away, because the wrong version
is the one a future reader is likely to re-derive). Supersedes §6.6's "deprioritized"
verdict at Brandon's request, 2026-08-26: *"I use Apple Reminders, and I'd
like to pull in Reminders due today or Reminders for a specific list(s)."*
The old verdict's reason (RemindersMenubar already covers it) is not wrong —
it is outranked by wanting one queue.

Everything under **Measured** was checked on this Mac on 2026-08-26 with a
throwaway `EKProbe.app`, signed Developer ID + hardened runtime + secure
timestamp and **no entitlements** — the app's Release posture minus
`apple-events`. Everything under **Unverified** was not.

---

## 1. Why a to-do is not a notification

A notification is an event: it happened, at a time, and the only question is
whether you have dealt with it. A task is a *commitment*: it has a due date in
the future, it can be edited, it recurs, and "I have seen this" and "I have
done this" are different facts about it.

That difference lands in exactly three places, and everything else is
ordinary connector work:

1. **Two verbs, not one.** `E` (done) means *dismiss* — strike it from the
   queue, keep it in the archive, leave Reminders untouched. `C` means
   *complete* — write through to Reminders. Today the protocol has only
   `markDone`, which conflates them.
2. **`occurredAt` has no obvious answer.** A task's salient time is in the
   future, and the queue is sorted by `occurredAt` descending. Picking the due
   date breaks dismissal (see §4 — this is the one real trap).
3. **A dismissed task is still in every snapshot.** Unlike a read Slack
   mention, it does not leave the remote queue when you dismiss it here. So
   `.remoteTruth` reconciliation has to be made to leave it alone.

## 2. Measured facts (EventKit, this Mac, 2026-08-26)

- **No entitlement is needed.** A hardened-runtime, Developer ID, unsandboxed
  app with `NSRemindersFullAccessUsageDescription` and *zero* entitlements
  called `requestFullAccessToReminders` and got `granted=true`, status
  `.fullAccess` (rawValue 3), and read all 12 list names. This is the
  **opposite** of the AppleScript case in CLAUDE.md rule 2 — do not add an
  entitlement "to be safe": Release ships exactly one entitlement and that
  should stay true. §6.6's entitlement note is correct but applies only to a
  sandboxed build (i.e. the declined MAS variant, PLAN §2.1.10).
- **`authorizationStatus(for: .reminder)` does not prompt.** Status was read
  as `0` (notDetermined) before any request. This is the EventKit analogue of
  `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)`, and it is
  what lets exactly one place in the app spend the consent prompt.
- **`predicateForIncompleteReminders(withDueDateStarting:ending:)` excludes
  undated reminders.** Measured: 8 matches for "due ≤ end of today", of which
  **0** were undated. So the due-today mode cannot accidentally pull in a
  wishlist.
- **The `ending:` bound is inclusive, and that is an off-by-one.** An all-day
  reminder is stored at 00:00 local, so a reminder due *tomorrow* sits exactly
  on `startOfDay(tomorrow)` and **leaked into the due-today window** in the
  measurement. Use `startOfDay(tomorrow) - 1s`, and cover it with a test.
- **All-day is the common case:** 5 of the 8 due-today reminders had no time
  of day (`dueDateComponents.hour == nil`). The row must not invent a clock
  time.
- **Recurring is the common case too:** 4 of 8. Not an edge case — the
  completion semantics in §5 are load-bearing.
- **Completing a recurring reminder is SAFE, and the mechanism matters.**
  Spike run 2026-08-26 in a scratch list: `isCompleted = true` + `save`
  completed *only today's occurrence*. EventKit split the reminder in two —
  a **new** reminder with a **new identifier**, `completed=true`,
  `recurring=false`, due today; and the **original identifier** carrying the
  series on, `recurring=true`, `completed=false`, due date rolled to
  **tomorrow**. The series was not destroyed. `C` on a repeating task is
  therefore fine, and the completed husk is invisible to
  `predicateForIncompleteReminders`, so it leaves no ghost row.
- **`lastModifiedDate` does NOT move when the occurrence rolls forward.**
  Both reminders read back with the *same* `lastModifiedDate` as before the
  completion, while the due date had changed. This killed the first draft of
  §4 — see the correction there. (An earlier sample showed a recurring
  reminder modified at 04:00 that morning, which *looked* like a roll bumping
  the field; that remains unexplained and is no longer relied on.)
- **An UNCOMPLETED recurring reminder does not roll forward.** Second spike,
  same day, with a daily-recurring reminder back-dated to yesterday and never
  completed: EventKit reported it still due yesterday, still incomplete, with
  the **same identifier**, and the due-today predicate returned it. Only
  *completion* advances the series. Three consequences, all good:
  - Yesterday's neglected occurrence **stays in the queue and goes overdue**
    rather than being silently replaced. "I skipped this" does not disappear.
  - The occurrence suffix is **stable while a task is overdue**, so there is
    **no daily archive row** — archive growth is one row per completion, the
    same as every other source. An earlier estimate of ~360 steady-state rows
    was wrong and is withdrawn.
  - Midnight is quieter than first described: only genuinely-newly-due
    reminders arrive then.
- **`completionDate` was `nil`** immediately after setting `isCompleted =
  true`. Don't read it back to confirm a write.
- **iCloud is the only writable reminder source on this Mac** (no `.local`
  source). Nothing in the design needs to create a list, but it means a
  scratch list cannot be kept off iCloud.
- **Unbounded is big:** all incomplete reminders across all lists = **135**,
  of which **70 are undated**. One list ("Maintenance") alone is **36**. A
  chosen-lists mode therefore needs a cap and `snapshotWasComplete()`.
- **`priority` is 0 on every sampled reminder** — Brandon does not use
  priorities, so high-signal must not depend on them.
- **`x-apple-reminderkit://` is handled by Reminders.app** (Launch Services
  resolves it). `x-apple-reminder://` is not.

### Measured cost (2026-08-26, real data, signed hardened-runtime build)

```
EKEventStore() init                          2.4ms
calendars(for:)  [12 lists]                  9.3ms
due-today fetch, cold  [5 results]           7.8ms
due-today fetch, warm  [5 results]           7.6ms
all incomplete, all lists  [135 results]    60.0ms
per-task calendar math, 135 tasks            0.4ms
```

**There is no cold penalty** — 7.8ms cold vs 7.6ms warm. This is the opposite
of `AppleMailConnector`, where the first Apple event after idle costs 12
*seconds*; that caveat does not transfer, and nobody should add a timeout or an
apology for a slow first poll here.

At a 60s cadence the duty cycle is 0.01% (due-today only) to 0.1% (with the
unbounded lists predicate). The redundant per-task work — `dueWindowEnd`
recomputed per task, `isOverdue` called twice per task by `kind` and
`highSignal` — measures under 1ms across 135 tasks and is deliberately left
alone: changing working code for a sub-millisecond win is risk for nothing.

### Unverified — spikes still open

1. **Whether `x-apple-reminderkit://REMCDReminder/<calendarItemIdentifier>`
   opens the right reminder.** Only the *scheme* is proven handled; the path
   shape and the identifier to use in it are guesses.
2. **Whether a consent alert actually appears.** The probe went notDetermined
   → granted within 6 seconds with no dialog observed, which is not proof
   either way. Standard EventKit behaviour is an alert; the design assumes one
   and puts it in one deliberate place.
3. **`EKEventStoreChanged` as a push signal.** §6.6 claims push for free.
   Believable, unmeasured, and *not* needed for v1 — poll 60s first.
4. **Whether editing a reminder bumps `lastModifiedDate`.** Plausible, and if
   it does, an edited task revives its row for free. §4 no longer *depends* on
   it either way.

**One thing about TCC worth writing down:** the probe was granted access when
launched with `open`, and refused (`granted=false`, `error=nil`, status stayed
notDetermined) when its executable was exec'd directly from Claude Code's
shell. Same signature, same bundle. So a permission check run from an agent's
shell can report a hard denial for a build that is actually fine — the
responsible process is the terminal, not the app. Launch the bundle, don't
exec the binary.

## 3. The generic seam (so Todoist is a thin connector, not a redesign)

New directory `Sources/App/Connectors/Todo/`:

- **`TodoTask.swift`** — a provider-agnostic value type: `id`, `title`,
  `notes`, `listName`, `due`, `isAllDay`, `priority`, `isRecurring`,
  `createdAt`, `modifiedAt`, `deepLink`.
- **`TodoItemMapper.swift`** — `nonisolated static` pure functions turning a
  `TodoTask` into a `RemoteItem`: `occurredAt(for:)`, `kind(for:now:)`,
  `highSignal(for:now:)`, `remoteItem(from:sourceKind:now:)`. This is where
  every decision in §4 lives, and it is testable with no EventKit and no
  network (CLAUDE.md rule 6).
- **`TodoScope.swift`** — parses the settings into a filter: due-window on/off
  plus the chosen list names, and computes the due window with the measured
  off-by-one handled in one place.
- **`RemindersConnector.swift`** — EventKit → `[TodoTask]`. Nothing else.

A future `TodoistConnector` supplies `[TodoTask]` from REST and reuses the
mapper, the scope, the `C` key, and the archive semantics for free. "Lists"
becomes "projects" with no change to the field shape.

## 4. `occurredAt` — the one real trap, and why `modifiedAt` wins

`Store.resurrectIfNeeded` revives a done item when
`remote.occurredAt > item.doneAt`. So if `occurredAt` is the **due date**, a
reminder due at 5pm that you dismiss at 2pm is revived on the very next poll —
dismissal would not stick at all, which is the headline behaviour Brandon
asked for.

Anything computed from `now` (e.g. `startOfToday`) fails differently: it moves
at midnight, so a dismissed reminder returns every morning.

`occurredAt` therefore has to be a fixed point in the *task's own* history:
**`modifiedAt ?? createdAt ?? due`**. That makes dismissal stick indefinitely,
which is the headline behaviour. ✅

**Correction — the recurrence half of this was wrong.** The first draft claimed
a recurrence rolling over would revive the row because `lastModifiedDate`
moves. The spike measured the opposite: the due date rolled from today to
tomorrow and `lastModifiedDate` did **not** change. So a repeating reminder
completed or dismissed once would have kept the same uid and the same
`occurredAt` forever, and **never come back** — a daily task would vanish from
the queue after its first appearance. Silent, and exactly the kind of
disappearance this app exists to prevent.

**The fix is identity, not timestamps.** For a recurring task the external id
carries the occurrence:

```
externalID = isRecurring ? "\(providerID)#\(dueDayISO)" : providerID
```

- Today's occurrence and tomorrow's are different uids, so tomorrow's arrives
  as a genuinely new row. No reliance on `resurrectIfNeeded` at all.
- Only one occurrence is ever in the window at a time (measured: the predicate
  returns the series at its current due date), so this yields one row per day,
  not a pile.
- Yesterday's uncompleted occurrence falls out of the snapshot and
  auto-archives under `.remoteTruth` — "that instance passed" — without
  bannering, since `reminders` will not declare `.announcesReturn`.
- **Non-recurring tasks keep a bare id on purpose**, so editing a due date
  updates the row in place instead of orphaning it and inserting a duplicate.

This is the *inverse* of the Claude Code `claude-done-<session>-<epoch>` bug in
CLAUDE.md, and worth not confusing with it: there, a timestamp in the id split
one long-lived thing into thirty rows. Here each occurrence really is a
separate commitment, and the suffix is a day, not an event time.

**The cost, stated plainly:** the queue's Age column and sort now reflect *when
the task last changed*, not when it is due. An overdue reminder does not float
to the top by position. Overdue urgency is carried by `highSignal` (which
`Store.update` already refreshes every poll) and by the row's kind, not by
ordering. If due-date ordering turns out to matter, that is a queue **sort
option** — a separate change, not a connector detail.

Due date, list, and repeat status show up as **context chips on `D`**, the way
Linear and GitHub already do it. Per the CLAUDE.md lesson from the Slack saves
bug: title = the reminder's title, `snippet` = its notes in full (uncapped, so
`D` has something to reveal). Never a preview in the title.

## 5. `C` = complete — the new capability

- `ConnectorCapabilities.completesTask` (`1 << 6`).
- `Connector.complete(externalID:payload:)` and
  `Connector.uncomplete(externalID:payload:)`, both defaulting to no-op.
  **`uncomplete` is not optional polish:** ⌘Z after `C` must un-complete in
  Reminders, or undo silently lies. EventKit makes it three lines.
- `SyncEngine.completeTask(...)` mirrors `markDone`: local done first, then
  write-through, then `notify(writeThroughFailure:)` so a failure is visible
  (rule 5).
- `Store.markDone(uid:reason:)` gains a reason, defaulting to `"user"`;
  completion passes `"completed"` so the archive can say *Completed* vs
  *Dismissed*. `"completed"` behaves like `"user"` in `resurrectIfNeeded` —
  only a moved `occurredAt` revives it, which is correct.
- Reminders declares `.completesTask` and **not** `.markDone`. That is the
  whole of "dismissing does not complete it": with no `.markDone`, the existing
  `E` path writes nothing remotely and the archive keeps the row.

Key surfaces, all three of which have to agree:

- **Panel** (`PanelView.handle`): `case "c" where filterText.isEmpty &&
  !isFiltering`. Bare `c` is free — only `e`/`s`/`u`/`d` are bound, and copy is
  ⌘C.
- **Main window** (`MainWindowCommands`): a Queue item with
  `.keyboardShortcut("c", modifiers: [])`, gated on a new
  `TriageActions.canComplete` and on `!isSearchFocused`, exactly like bare `E`.
- **Archive** (`ArchiveView`): completing a *dismissed* reminder must still
  work, or dismissing costs you the ability to finish it from the app.

Pressing `C` on a non-task row must **say so** via the `PanelHint` bubble
rather than doing nothing (rule 5).

## 6. Settings, permission, and packaging

- **Descriptor:** `id: "reminders"`, `displayName: "Apple Reminders"`,
  `systemImage: "checklist"`, `allowsMultiple: false` (one Reminders database
  per Mac, same argument as Apple Mail).
- **Fields** (Brandon's decisions, 2026-08-26):
  - `dueToday` toggle, default **on** — "Due today or overdue".
  - a **list picker** (multi-select) rather than free text; the real list names
    are enumerable once access is granted, and typing them invites typos.
    Store titles, not identifiers — readable and debuggable, and a title that
    no longer exists is reported in the editor rather than silently dropped
    (rule 5).
  - `listsIncludeUndated` toggle, default **off**. A chosen list contributes
    only its reminders that have a due date; the toggle opens it to undated
    ones. Measured reason: 70 of 135 open reminders here are undated and
    "Maintenance" alone is 36, so the unfiltered version buries the queue on
    first connect. The escape hatch is one checkbox rather than an invisible
    cap.
  - The two modes are OR'd, per the ask.
- **`RemindersAccessSection`** in the source editor is the **only** caller
  that requests access, mirroring `MailAccessSection` — the explanation is on
  screen when the dialog lands. `RemindersConnector.fetch()` only ever *reads*
  `authorizationStatus` (measured: free, no prompt).
- **`fetch()` must throw, never return `[]`, when access is not granted.**
  With `.remoteTruth` an empty snapshot means "the user handled all of these"
  and would archive every task row. This is the Apple Mail `-1743` lesson
  exactly: a permission failure that looks like an empty inbox.
- **Cap the snapshot** (suggest 200) and answer `snapshotWasComplete() ==
  false` when capped, or a big chosen list sets up the GitHub resurrect loop.
- **`project.yml`:** add `NSRemindersFullAccessUsageDescription` to the
  generated `info:` block (§6.6 is right that it is mandatory), link
  `EventKit.framework`, and **add a comment saying no entitlement is needed
  and why**, so nobody adds one later.
- **`scripts/verify-bundle.sh`:** `expect_plist_present
  NSRemindersFullAccessUsageDescription` — CLAUDE.md asks for a check
  whenever a new plist key is read at runtime.
- **`AppState.openable`:** allow `x-apple-reminderkit` **only** when
  `sourceKind == "reminders"`, the same local-only gate `file` and `claude`
  get. A remote push must not be able to fabricate one.
- `JournalWriter`: a `.completed` verb, so the journal distinguishes finishing
  a task from dismissing it.

## 7. Tests (all pure, no EventKit)

Insert **mid-file** in `Tests/TriageTests.swift` / a new
`Tests/TodoMappingTests.swift`, per the parallel-session rule.

1. `occurredAt` is never in the future — the regression guard for §4.
2. **Dismissal sticks:** mark done with reason `"user"`, reconcile the same
   `RemoteItem` again, assert still done. This is the trap; it needs a test.
3. **A recurring task's next occurrence is a new uid**, and a non-recurring
   one's is not — the regression guard for the corrected §4. Assert the day
   suffix appears only when `isRecurring`.
4. The due-window off-by-one: an all-day task due tomorrow is excluded.
5. `kind`/`highSignal` boundaries at overdue / due-today / undated.
6. Undo after complete calls `uncomplete` (fake connector).
7. `listsIncludeUndated` off drops undated tasks from a chosen list, on keeps
   them.

## 8. Order of work

One PR, built in this order — dismissal semantics only make sense next to `C`:

1. ~~Spike: recurring completion.~~ **Done 2026-08-26 — safe**, see §2.
2. `TodoTask` + `TodoItemMapper` + `TodoScope` + their tests.
3. `RemindersConnector.fetch()`, descriptor, access section, plist,
   `verify-bundle.sh`.
4. `.completesTask`, `complete`/`uncomplete`, engine + store, `C` on all three
   surfaces, undo, journal verb.
5. Context chips on `D`, deep-link + `openable` allowlist (spike #1 first).
6. `scripts/install-local.sh` and verify against the installed binary — rule 1.
   `xcodebuild test` proves nothing about a TCC-gated source, and per §2 a
   permission check run from an agent's shell can lie.

**Not in scope, recorded so it is a decision and not an omission:** overdue
reminders are flagged high-signal but do not float to the top of the queue by
position (Brandon's call, §4). If that turns out to matter, it is a queue sort
option — a separate change.

## 9. Todoist — the second provider (added 2026-08-26)

The original text here said Todoist was deliberately not in this PR, the seam
being the deliverable. It is now in its own follow-up, and the seam held: two
new files (`TodoistAPI`, `TodoistConnector`) plus a project picker, and **no
change at all** to `TodoTask`, `TodoScope` or `TodoItemMapper`'s decisions. The
only edits to existing to-do code were additive or tidying — a
`TodoPriority.fromTodoist` beside `fromEventKit`, `rank` moved from
`RemindersConnector` up into `TodoItemMapper` where both providers reach it,
and the chips moved into a shared `TodoContext`.

What Todoist needed that Reminders did not:

| | Reminders | Todoist |
|---|---|---|
| Source of truth | EventKit, local | REST v1, network |
| Permission | TCC dialog | a pasted API token |
| "Lists" | reminder lists | projects |
| Due window | two predicates | filter query `overdue \| today \| tomorrow` |
| Completeness guard | a 200-task cap | cursor pagination *and* the cap |
| Poll | 60s | 120s — it costs a round trip |
| Undo after `C` | restores | **lossy on a repeating task, and says so** |

That last row is the one real behavioural difference, and it is Todoist's, not
ours: `close` on a recurring task reschedules it instead of completing it, so
there is nothing for `reopen` to put back. `TodoistConnector.uncomplete`
reports that rather than letting an undo half-work in silence.

**The same latent gap exists in `RemindersConnector` and is not fixed here.**
EventKit rolls a recurring reminder the same way, so `uncomplete` setting
`isCompleted = false` on the rolled original does not restore the old due date
either — it just does not say so. Worth a follow-up; out of scope for the
connector that noticed it.

### Verification status

Every shape in `TodoistAPI` comes from Todoist's published OpenAPI document,
fetched 2026-08-26 — not from memory, which mattered: the current API is the
unified **v1**, and a connector written against the widely-remembered
`/rest/v2/tasks` would 404 on every call.

Rule 4 applied in full until it didn't: **Brandon pointed a real token at it
on 2026-08-26**, and the reading path holds. His tasks arrived in the queue, a
task due at a time today showed that time, and `C` on a repeating task
produced the next occurrence as its own row. That last one is the important
result — it exercises both the `due.date` parsing the document left loosest
*and* the occurrence-day identity, which were the two most likely places for
this to be quietly wrong.

**Three paths remain unexercised**, and a passing read path is not evidence
for any of them:

- **Undo after `C` on a repeating task** — the deliberately lossy branch, and
  the only place this connector's behaviour differs from Reminders'.
- **Paging past the first page.** `next_cursor` handling has never actually
  had a second page to fetch, and this is the one that would fail *silently*
  and destructively: a mishandled cursor plus `.remoteTruth` archives the tail.
- **The rejected-token path** (401), including whether the project picker's
  error reads well when the token is wrong rather than absent.
