# Inbox & Chill — working notes for agents

Native macOS menu bar app (macOS 15+, SwiftUI + SwiftData) that aggregates one
triage queue from Slack, Linear, GitHub, ntfy, and local producers
(the `inchill` CLI, Claude Code hooks).

`PLAN.md` is the design source of truth. This file is the operating manual:
the things that have actually bitten, and the conventions to keep.

## Reporting to Brandon

Short, direct, accurate. He reads on mobile, so wide tables and long code
lines hide their most important words off-screen to the right — put the point
in the first few words of a line.

- **Verify before asserting.** State what you checked and how. If you did not
  check it, say so. A confident wrong answer costs more than a slow one.
- **Don't narrate the work.** Report the finding and what it means. Skip the
  route you took to it unless the route *is* the finding.
- **One correction, then move on.** No re-litigating, no tallying your own
  mistakes, no apologising twice.
- **Separate severities.** "This is broken", "this is a latent risk" and
  "this turned out fine" must not be delivered at the same volume.
- **Run a check on this machine before you conclude anything about the repo.**
  Web sessions get a shallow clone (`git rev-parse --is-shallow-repository`),
  which silently changes what git and gitleaks report. Verified 2026-08-22,
  after three wrong conclusions in a row drawn from one.

## Commands

```bash
xcodegen generate                                        # after editing project.yml
xcodebuild -project InboxAndChill.xcodeproj -scheme InboxAndChill -configuration Debug test
scripts/check-shell.sh                                   # what CI runs on scripts/
scripts/verify-bundle.sh                                 # audit a built .app (see CI, below)
scripts/install-local.sh                                 # Release → /Applications → launch
scripts/reset-first-run.sh --dry-run                     # back to a fresh install (see below)
scripts/release.sh --dry-run                             # show what a release would do
scripts/release.sh                                       # notarize + tag + release + appcast (runbook: docs/releasing.md)
scripts/sparkle-keys.sh                                  # ONE TIME: create the update-signing key
scripts/appcast.sh                                       # regenerate appcast.xml from dist/
```

Tests are Swift Testing (`@Test` / `#expect`), in `Tests/`.

## How work lands: a PR, always

**Do not push to `main`.** Branch, open a PR, let Brandon review it. This
changed on 2026-08-21 and the reason is simply that he is no longer the only
person committing here — the repo had no PR flow because it had one author, and
that stopped being true.

```bash
git checkout -b <kind>/<short-name> origin/main   # fix/… feat/… docs/…
# work, commit
git push -u origin <branch>
gh pr create --title "…" --body "…"
```

Two things that follow from more than one contributor, and bite quietly:

- **Rebase on `origin/main` before you push, and check what came in.** Guest PRs
  land between your first commit and your last. `git diff --stat HEAD origin/main`
  tells you whether they touched anything you touched; if not, a rebase is free.
- **`CURRENT_PROJECT_VERSION` is a merge magnet.** Every release bumps it, so two
  branches that both bump it conflict. Leave it alone in feature branches — the
  release bump is its own commit on `main`.

### CI runs on every PR (added 2026-08-21)

`.github/workflows/` — full explanation, including what it deliberately does
not do, in `docs/ci.md`. The short version, and the parts that change how you
work here:

- **CI never signs anything for real.** No Developer ID certificate, no notary
  credentials, no Sparkle private key reaches a runner; builds there are
  ad-hoc signed. So CI cannot tell you a build is notarizable — that is still
  `scripts/notarize.sh --preflight-only` on a Mac, and it is still the only
  thing that can.
- **A green CI run is not rule 1 satisfied.** It runs `xcodebuild test`, which
  installs nothing. "Ran against a real install" still means
  `scripts/install-local.sh` and a check against the installed binary, and the
  PR template asks you to say so either way.
- **`scripts/verify-bundle.sh` is the new regression guard for the Info.plist
  traps.** Nothing checked SUFeedURL, the version keys, or LSUIElement before
  — the `INFOPLIST_KEY_SUFeedURL` bug shipped a bundle with no feed URL and no
  stage warned. Add a check there when you add a plist key something reads at
  runtime. It runs on PRs that touch `project.yml`, the entitlements file,
  `scripts/`, or the workflows; and on every merge to `main`.
- **`scripts/check-shell.sh` enforces the bash 3.2 array rule** from rule 3, by
  grepping. An array that provably can never be empty is excused with a
  `# bash32-ok` comment above the line, saying why — `release.sh` has the one
  example.
- **Actions is free now the repo is public** (since 2026-08-21). It was not:
  macOS minutes billed at 10×, which is why the cheap checks are on Linux and
  why the Release audit is conditional. Those two stay — Linux is faster
  regardless, and the audit is a second full build whose findings all live in
  `project.yml`, the entitlements file or `scripts/`. Adding a second macOS
  job is no longer a cost decision, just a time one.

- **A shallow clone moves gitleaks findings, it does not just hide them.**
  Cost an hour on 2026-08-22. gitleaks attributes a finding to the commit
  whose *diff* introduces it. Truncate history and the oldest commit you kept
  looks like a root commit that added the whole tree, so every secret in it is
  re-attributed to *that* commit — which then misses the commit-scoped
  allowlist in `.gitleaks.toml`, and the exemptions look stale when they are
  perfectly fine. The two SHAs in there are correct and reachable from `main`;
  verified in a full clone. Claude Code web sessions get shallow clones, so if
  a local scan disagrees with CI, run
  `git rev-parse --is-shallow-repository` before concluding anything about the
  repo.

Releases are still cut from `main`, after merge: `release.sh` refuses to run from
any other branch, on a dirty tree, or out of sync with `origin`.

Nothing about the review rules changes for an agent: say plainly what you did
**not** verify (rule 1), and do not contradict a recorded verdict without
reading it first (rule 4). A PR body is a good place for both.

## The six rules that keep being learned the hard way

### 1. `xcodebuild test` installs nothing

"BUILD SUCCEEDED" and "TEST SUCCEEDED" say nothing about what is running. Before
claiming a feature works, or telling the user it is available, run
`scripts/install-local.sh` and verify the change is in the installed binary:

```bash
strings -a "/Applications/Inbox & Chill.app/Contents/MacOS/Inbox & Chill" | grep -c "<a literal you just added>"
```

Two traps in that check:

- **Pick a literal longer than 15 UTF-8 bytes.** Swift stores short strings
  inline (small-string form) rather than in `__TEXT`, so `strings` reports `0`
  for them *even in a correct build*. Expect **2** hits, not 1 — it is a
  universal binary.
- **Presence proves presence; absence proves nothing.** Optimised-away symbols
  give false negatives. To prove a removal, use the test suite.
- **Pick a literal with no non-ASCII characters.** `strings` only emits runs of
  printable ASCII, so one curly apostrophe splits the literal in two and the
  grep reports `0` for a string that is right there. `Mail wouldn’t describe
  this message` returns nothing; `t describe this message` returns 2. Hit this
  on 2026-08-19 — if a literal you are sure about reports `0`, check it for
  typographic punctuation before believing the build is stale.

mtime and size are not evidence. A behavioural test that "fails" is very often a
stale binary.

**Logging: `log` is a zsh builtin, and it shadows `/usr/bin/log`.** This note
used to say "`log show` does not work for this app", which was wrong and cost
several cycles of believing code wasn't running. The "too many arguments"
error is zsh's own `log` builtin refusing the arguments — nothing to do with
the predicate, the subsystem, or the log level. **Corrected 2026-08-26**;
`/usr/bin/log show --last 7d` returned 117 lines for this subsystem
immediately.

Always spell the path:

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "lol.bgreen.inboxandchill"' --style compact
/usr/bin/log stream --predicate 'subsystem == "lol.bgreen.inboxandchill"' --info --debug --style compact
```

One real constraint remains, and it is about *levels*, not tooling: `.debug`
and `.info` may live only in a memory buffer and never reach disk, so a line
logged at those levels dies with the process. Anything a crash report should
carry has to be logged at the default level or above — see `AppLog`.

### 2. AppleScript needs an entitlement, not just a usage string

**A hardened-runtime app cannot send Apple events without
`com.apple.security.automation.apple-events`.** Without it macOS refuses every
event with `errAEEventNotPermitted` (**-1743**) and shows **no consent prompt at
all** — the app is not permitted even to ask, so nothing appears in Privacy &
Security → Automation for the user to allow. `NSAppleEventsUsageDescription`
supplies the prompt's *wording*; the entitlement supplies the *right to be
prompted*. Necessary and not sufficient, in that order.

This shipped broken in 0.3.0 and cost real time because every symptom pointed
elsewhere: the source polled happily every 60s, logged -1743 every time, and
looked exactly like an empty inbox. It silently broke **two** features — the
Apple Mail source and the Claude Code terminal-tab focus (`ClaudeSessionOpener`)
— and `ENABLE_HARDENED_RUNTIME` is in `settings.base`, so Debug was affected
too. Tests passed throughout, because the tests only exercise pure helpers.

Diagnosis order that actually worked, when an Apple event fails:

1. `codesign -d --entitlements - <app>` — is the entitlement there at all?
2. `log show --last 5m --predicate 'subsystem == "com.apple.TCC"'` — **silence
   means TCC was never consulted**, which means the refusal happened before
   consent, which means the entitlement. A *denial* would appear here.
3. Only then suspect TCC state or the user having declined.

**And never `first <element> whose …`.** When the filter matches nothing, Mail
raises "Invalid index" (**-1719**), which names nothing and sent this
investigation down a thread-safety dead end. `count of (messages … whose …)`
returns 0, so a miss becomes a fact you can attach a sentence to. This was the
0.3.0 `markDone` bug.

Related: **log the AppleScript error *message*, not just its number.**
`NSAppleScript.errorBriefMessage` said "Invalid index" and named the bug
outright; `-1719` on its own cost an hour.

**And exactly one place in the app may spend the Automation prompt.** macOS
shows that dialog once per app per target and never again, so *who* triggers it
decides whether the user ever understood what they were agreeing to. For Mail
that place is `MailAccessSection` in the source editor — the only caller that
passes `prompting: true` — and it renders
`MailAutomationAuthorization.preflight` above the button, so the explanation is
on screen when the dialog lands. Everything else, `AppleMailConnector.fetch()`
included, calls `MailAutomation.resolve(prompting: false)`, which
`AEDeterminePermissionToAutomateTarget` answers **without** prompting when
`askUserIfNeeded` is false. That is the primitive worth remembering: the app can
read its own permission state for free.

Two consequences that look like bugs and are not:

- **A closed Mail does not poll** (`Outcome.allowsFetch` is true only for
  `.granted`). `tell application "Mail"` *launches* Mail, so fetching with
  permission unknown would raise the dialog from a 60s timer, which is the
  whole failure being prevented.
- **Adding a `prompting: true` caller is a regression**, even a well-meaning
  one on first launch. If a new AppleScript target needs consent, give it its
  own preflight rather than widening an existing one.

`ClaudeSessionOpener` is the other Apple-event caller and is already fine: it
fires on ⏎ against a *terminal* (a different TCC target), so its prompt is
attributable to a keypress the user just made.

### 3. Quote every path you hand to a shell

The bundle is `Inbox & Chill.app`. A shell reads the `&` as a background-job
separator and silently splits the command in two — this killed the Claude Code
hooks once already. `ClaudeCodeIntegration.shellQuoted` exists for this; use it
for any hook, script, or `sh -c` string. When patching JSON written by
Foundation, remember `/` arrives escaped as `\/`.

To debug a hook that "silently doesn't fire", run the *stored command string*
the way the harness does — `sh -c "$CMD"` — not the binary with your own
quoting. The latter hides the bug.

**And these scripts run under bash 3.2, not the bash you have in mind.** macOS
still ships 3.2.57, where expanding an **empty array** under `set -u` is an
"unbound variable" *error*, not an empty expansion:

```bash
ARGS=()
cmd "${ARGS[@]}"                    # bash 3.2 + set -u: fatal
cmd ${ARGS[@]+"${ARGS[@]}"}         # correct
```

This shipped broken in `appcast.sh` on 2026-08-21 and would have failed **every
real release**: the array was only non-empty when an env var supplied a key
file, which is exactly the path used while testing, so the tested path worked
and the default one — read the key from the Keychain — died. If a script takes
an optional-flags array, use the `+` form. Every script here starts
`set -euo pipefail`, so this is not hypothetical.

Also worth knowing when checking secrets: **`gitleaks` defaults to the working
tree only.** The scan that matters is

```bash
gitleaks detect --source . --log-opts="--all" --redact
```

`.gitleaks.toml` holds one deliberate exemption (Sparkle's *public* key) and
explains why a global allowlist must not use `paths` — it ORs with `regexes`
rather than ANDing, so a path filter exempts the whole file.

### 4. Read the verdicts this repo already recorded

Before proposing a connector change or answering an API-capability question,
read: `PLAN.md` §6.9, the `authNote` strings in `Sync/ConnectorCatalog.swift`,
and the doc comments on the connector itself. They carry verified verdicts with
their reasoning. Contradicting one has cost real time more than once — e.g.
offering a Slack `search.messages` rework that `SlackConnector`'s own header had
already ruled out.

Related: **a config file that has never been fed to the real service is
unverified, however carefully it was written.** `docs/slack-app-manifest.yml`
was wrong in three ways the first time it met Slack's validator. Say so plainly
when handing over something untested.

### 5. Silent failure is this project's recurring bug class

Nearly every bug here was something returning bare on a permission problem, a
missing scope, or a rejected token — indistinguishable from "nothing happened".
The app exists to stop things being dropped, so **a failure the user cannot see
is worse than a crash.** When adding a path that can fail:

- surface it (status dot `.error`, a red message in Settings, a named reason),
- say what to do about it, not just what went wrong,
- never `try?` a write-through.

Precedents to copy: `SlackConnector.userTokenProblem(_:)`,
`SlackConnector.searchScopeAdvice(code:)`, `NtfyConnector.status(forHTTPStatus:)`,
`JournalWriter.explain(_:url:)`, `BannerAuthorization`.

### 6. Put logic in `nonisolated static` pure functions

Connectors are actors and their real work needs network + Keychain, so anything
worth testing belongs in a pure static helper the tests can call directly.
Follow `NtfyConnector.item(from:)`, `JournalWriter.line(for:)`,
`LinearConnector.headline(type:entity:)`, `SlackConnector.watchHit(...)`.

## Architecture

- `Sync/Connector.swift` — the protocol. Identity properties (`sourceID`,
  `sourceKind`, `capabilities`, `pollInterval`) must be `nonisolated`.
- `Sync/SyncEngine.swift` — drives polling and push connectors; re-invokes
  `run()` on the **same** connector instance after a 5s backoff, so in-memory
  cursors survive reconnects.
- `Sync/Store.swift` — `@ModelActor` over SwiftData. Owns done/snooze/pin/purge.
- `Sync/ConnectorCatalog.swift` — declares each source kind's settings fields
  (`isSecret`, `isToggle`/`defaultOn`) and its `authNote`.
- `AppState.makeConnector` — wires settings JSON into connector inits.
- `Support/Keychain.swift` — service `lol.bgreen.inboxandchill`, account is
  `<sourceConfig UUID>.<field>` (**not** `<kind>.<field>`). Read-through cached
  because connectors call it per operation.

### Capabilities, and the one invariant that matters

`.remoteTruth` means "items absent from a snapshot were handled remotely and
should auto-archive". That is only safe if the snapshot can enumerate
*everything*. Two consequences, both load-bearing:

- A truncated snapshot must never drive archiving — hence
  `Connector.snapshotWasComplete()`, ANDed with `.remoteTruth` in `pollOnce`.
  (GitHub's `/notifications` caps at 50 per page; not paginating once caused an
  unkillable resurrect loop over ~946 items.)
- `SlackConnector` declares `.remoteTruth` but **deliberately never emits
  `.snapshot`** — mentions exist only in its memory of witnessed events, and
  Socket Mode reconnects every ~10 minutes would archive them all.

`Store.resurrectIfNeeded` revives a done item only when `doneReason == "remote"`
or `remote.occurredAt > doneAt`. This is why re-emitting an item the user
dismissed is safe as long as `occurredAt` is the real event time.

`.completesTask` is a **second write-through verb**, not a variant of
`.markDone`. A notification has one end state; a task has two — *seen* and
*done* — so a to-do connector declares `completesTask` and **not** `markDone`,
which is what makes `E` leave the source untouched while `C` finishes the task.
Anything declaring it must also implement `uncomplete`, or ⌘Z restores the row
while leaving the task ticked off. `Store.undoDone` returns the `DoneReason` so
the engine can tell the two apart.

## Task groups in connectors — two ways to lose a source

`run()` uses `withThrowingTaskGroup` with `_ = try await group.next()`, so **the
first child to finish tears down all its siblings** and the SyncEngine restarts
the connector 5s later. Two failures have come from this:

- **A child that returns immediately kills the connector.** Slack's keyword
  watch returned early when no terms were configured — the default — which
  would have restarted the whole source every 5 seconds, taking DMs and
  mentions with it. Either don't add the task, or make it park rather than
  return.
- **Don't put independent work downstream of `seed()`.** `seed()` walks every
  conversation in the workspace; on a large one it takes minutes. Anything
  awaiting it before starting effectively never starts. The keyword watch
  shipped this way and ran zero times against a workspace where Slack was
  returning 45 matches.

## Connectors

| Kind | Transport | Capabilities | Notes |
|---|---|---|---|
| `linear` | GraphQL poll 30s | markDone, remoteSnooze, remoteTruth | Per-type inline fragments; `DocumentNotification` has no `document` relation (resolved by a second `documents(filter:)` pass). `Notification.subtitle` is the comment **body**, not a name. |
| `github` | REST poll | markDone, remoteTruth | Classic PAT only (OAuth tokens rejected). Paginates; `participating=true` by default. |
| `slack` | Socket Mode + poll | markDone, remoteTruth, push | User token `xoxp-` required; app-level `xapp-` optional (adds channel mentions). Keyword Watch polls `search.messages` — the only way to see a channel you're not in. Mute Channels drops keyword hits *and* real mentions from named channels (never DMs or emoji saves). |
| `ntfy` | WebSocket | push | No remote read-state; items die by explicit done. `since=<id>` is exclusive-after. |
| `jsonPoller` | HTTP poll 120s | remoteTruth | Generic: any URL returning a JSON array or `{items: [...]}`, fields mapped via a user-supplied `id=id,title=title,...` string. Optional bearer auth header from the Keychain. |
| `local` | HTTP listener | push | `inchill` CLI + Claude Code hooks. Push-only: it sees only what a hook POSTs. A Claude Code item opens the **session**, not its folder — see below. |
| `sentry` | REST poll 60s | markDone (opt-in), remoteTruth | `?query=is:unresolved is:for_review&sort=inbox` — Sentry's For Review tab *is* the queue. Resolving is **off by default**: it's team-visible, so a local done just means "seen" and the item returns via `resurrectIfNeeded` when `lastSeen` moves. Cursor pagination via `Link` → needs `snapshotWasComplete()`. |
| `appleMail` | AppleScript poll 60s | markDone, remoteTruth | **Covers Gmail** — it reads every account Mail has, which is why there is no Gmail connector (PLAN §6.13). Flagged-only by default. See below. |
| `reminders` | EventKit poll 60s | **completesTask**, remoteTruth, providesContext | Apple Reminders. Declares `completesTask` and deliberately **not** `markDone` — that omission is the dismiss-vs-complete feature. No entitlement needed; 7.8ms cold, so no Mail-style cold penalty. See below. |
| `todoist` | REST poll 120s | **completesTask**, remoteTruth, providesContext | Todoist, via a personal API token. Same to-do semantics as `reminders` — `E` dismisses locally, `C` closes in Todoist. **API v1 only** (`api.todoist.com/api/v1`); REST v2 and Sync v9 are gone. Undo is honestly lossy on a repeating task. See below. |

### A to-do is not a notification (`reminders`, `todoist`)

Three things here were arrived at by measuring EventKit, and two of them are
the opposite of what the rest of this file would lead you to expect. Full
numbers and method in `docs/todo-sources-plan.md`.

- **EventKit needs NO entitlement.** A Developer ID, hardened-runtime,
  unsandboxed build with *zero* entitlements gets full Reminders access.
  `NSRemindersFullAccessUsageDescription` is mandatory — its absence is a
  **crash**, not a denial — and `verify-bundle.sh` guards it. Do **not** debug
  an empty Reminders source by adding an entitlement: this is not rule 2's
  Apple-events case, and Release ships exactly one entitlement on purpose.
  (PLAN §6.6's entitlement note is correct but applies only to a *sandboxed*
  build, i.e. the declined MAS variant.)
- **There is no cold penalty.** 7.8ms cold vs 7.6ms warm, against Mail's 12
  *seconds*. Don't copy Mail's "a slow first poll is normal" caveat here, and
  don't add a timeout for a problem this source doesn't have.
- **`occurredAt` is `modifiedAt`, never the due date.** A due date is in the
  future, and `resurrectIfNeeded` un-dismisses anything whose `occurredAt`
  passes its `doneAt` — so a reminder due at 5pm dismissed at 2pm would come
  straight back. Anything derived from `now` returns every midnight instead.
  The cost is accepted deliberately (Brandon, 2026-08-26): overdue tasks are
  high-signal but do **not** float to the top by position. Due date, list and
  repeat status are chips on `D`.
- **A recurring task's external id carries its due day**, and this is the
  *inverse* of the `claude-done-<session>-<epoch>` bug below — don't "simplify"
  the suffix away. `lastModifiedDate` does not move when a completion rolls the
  occurrence forward, so with a bare id a daily reminder would be completed
  once and never reappear. An **uncompleted** occurrence does not roll at all:
  it stays put and goes overdue, so the suffix is stable while you neglect a
  task and there is no per-day archive row. Non-recurring tasks keep a bare id
  so rescheduling updates the row in place.
- **`fetch()` throws rather than returning `[]`** when access isn't granted.
  With `.remoteTruth` an empty snapshot means "the user handled all of these"
  and would archive every task row — the Mail `-1743` failure with a bigger
  blast radius.
- The `ending:` bound of `predicateForIncompleteReminders` is **inclusive** and
  all-day reminders sit at 00:00, so the start of tomorrow lets a task due
  *tomorrow* in. `TodoScope.dueWindowEnd` is one second earlier.

Everything behavioural lives in
`Connectors/Todo/{TodoTask,TodoItemMapper,TodoScope,TodoContext}`, pure and
tested with no EventKit and no network; each connector is *provider in,
`[TodoTask]` out* and nothing more. Note EventKit's types are **not
`Sendable`**: the UI and the connector hold separate `EKEventStore`s and
`EKReminder` is mapped inside the `fetchReminders` callback. TCC consent is
per-process, so nothing is lost by not sharing.

**The seam held.** Todoist added two files and changed none of the four above
— which is the thing to preserve. A third provider that needs
`TodoItemMapper` changed is a signal the change belongs in that provider, not
in the mapper.

#### Todoist's own traps (all from its OpenAPI document, 2026-08-26)

None of these was verified when written — all four came from the document.
Brandon then pointed a real token at it the same day, and the reading path
holds: his tasks arrived, a task due at a time today showed that time, and `C`
on a repeating task produced the next occurrence as its own row. **Three paths
are still unexercised** and should not be trusted on the strength of that:
undo after `C` on a repeating task, paging past the first page, and the
rejected-token path.

- **`priority: 1` is the default every task carries**, and 4 is urgent — the
  inverse of EventKit, *and* the inverse of the labels Todoist's own UI prints
  (its "P1" is `priority: 4`). Mapping 1 to anything but `.none` makes the
  high-signal badge fire on the entire account.
- **`due.date` carries both shapes** — `2026-08-26` for all-day, a full
  timestamp for a timed task — so the string's own form is the all-day
  discriminator. The timed form is sometimes *floating*, with no zone
  designator, which `ISO8601DateFormatter` rejects outright; `ISO8601Timestamp`
  alone would silently drop every timed task's due date. Todoist also sends
  **six** fractional digits, one past what that formatter is specified for.
- **`close` on a recurring task reschedules it rather than completing it**,
  keeping the same id — identical to EventKit, and the reason the occurrence
  day in the external id is load-bearing here too. It also makes **undo
  genuinely lossy**: there is nothing for `reopen` to restore and no call that
  brings the old due date back, so `uncomplete` *says so* rather than
  half-working in silence.
- **`next_cursor` is the only end-of-list signal.** A short page is not the
  end. Stopping early without reporting the snapshot incomplete would hand
  `.remoteTruth` a truncated list, which archives everything past the cut.
- **`GET /tasks` has no due-date parameter**, so the due window goes through
  the filter language and chosen projects through `project_id` — two requests
  unioned by task id, the same shape `RemindersConnector` uses. The filter
  query deliberately asks for `tomorrow` as well: Todoist evaluates `today` in
  the *account's* timezone, and `TodoScope.accepts` is the gate that makes this
  Mac's clock authoritative.
- **Ids are opaque alphanumeric strings and there is no `url` field**, so the
  deep link is constructed. It is `https`, which `AppState.openable` already
  admits — this source widens no scheme.
- The project picker in the source editor is **also the token check**, on
  purpose: a bad token otherwise produces a source that looks like a free
  afternoon. There is no second "Check Connection" control saying it again.

### One queue row per Claude Code session, not per turn

The `Stop` hook used to post `claude-done-<session>-<epoch>`, so **every turn
ending created a brand-new item** — a thirty-turn session left thirty
near-identical rows and buried the only fact worth keeping. All four hooks now
address the same id, `claude-<session_id>`, and the row updates in place:

| Hook | Effect on the row | Signal |
|---|---|---|
| `Notification` | upsert — Claude wants you (permission, or 60s idle) | high |
| `Stop` | upsert — turn ended, carries what Claude last said | low |
| `UserPromptSubmit` | **clear** — you replied | — |
| `SessionEnd` | clear — the session is gone | — |

Three things that look like oversights and are not:

- **`Stop` stays low-signal.** An ignored finish goes idle, `Notification`
  re-fires ~60s later, and the same row turns high-signal. Urgency rises with
  neglect without anything having to track neglect.
- **`UserPromptSubmit` is load-bearing, not a nicety.** It is the only thing
  that makes the queue mean *sessions awaiting my reply* rather than *sessions
  I have ever run*; without it a live session's row never leaves.
- **The hooks exit 0 even when the app is closed** (`post(bestEffort:)`), which
  is a deliberate exception to rule 5. `UserPromptSubmit` runs on every prompt
  the user sends, so a non-zero exit with the app shut would put an error in
  front of them every time they typed. The reason still goes to stderr (visible
  in ctrl-R) and the Settings row is the better place to say hooks aren't
  landing. A human-typed `inchill notify` still fails loudly.

Two knock-on changes, both needed because a row now *lives*:

- **`.announcesReturn`, a new capability, opt-in per connector.** A revived
  item — done, then spoken about again — is reported in
  `ReconcileResult.inserted`, which is what banners and journal arrivals key
  off. `local` declares it and nothing else does: a Claude Code session's
  second and later finishes revive its row rather than inserting one, so
  without this only the first time a session ever waited on you would reach
  you. Threaded from capabilities exactly like `remoteTruth`
  (`SyncEngine.register` → `Store.reconcile`/`apply`).

  **Deliberately not the default.** Brandon's call, 2026-08-20: *"i'd rather
  keep it to specific sources, i want to see how other sources feel first.
  claude code is kind of unique imo"* — the change was originally Store-wide,
  which would have made Sentry banner every time a "done means seen" issue's
  `lastSeen` moved. Widening it is a decision to take with him. The
  regression guard is `resurrectionIsSilentByDefault` in `Tests/TriageTests.swift`.
- **`update()` refreshes `kind`.** It was frozen at insert, so a row born
  `claude_done` still claimed to be one after becoming `claude_waiting`. This
  one *is* global — the source is authoritative about what an item is, and a
  refreshed `kind` produces no user-facing noise.

Adding hooks to an existing install is why `ClaudeCodeIntegration` reports
three states rather than a Bool: `.outdated` (our hooks are there but not the
ones we would write today) is what an upgrade looks like, and Settings offers
"Update Integration" for it.

### Opening a Claude Code item lands in the session

The hook records *where the session runs* (`sessionOrigin()` in
`Sources/CLI/main.swift`), and `ClaudeSessionTarget` turns that into a jump.
Three facts that cost a while to establish:

- **Claude desktop sessions** export `CLAUDE_CODE_HOST_SESSION_ID`
  (`local_<uuid>`) and the app registers `claude://local_sessions/<id>`, which
  navigates to the live session.
- **Never `claude://resume?session=<cli id>`.** That route *imports the
  transcript as a new desktop session* — verified 2026-08-19 by firing it:
  it logged "importing CLI session", warmed a fresh `local_…` session and
  started a shell. For a live session that is a duplicate, not a jump.
- **Terminal sessions** are found by tty, and getting the tty right is the
  whole trick: the hook's stdin is a pipe, and both `ttyname()` and
  `devname()` on a `/dev/tty` descriptor answer `/dev/tty` (a cloning device
  reporting itself), which matches no tab while looking perfectly fine in the
  payload. Read the kernel's per-process `e_tdev` via `sysctl` instead.

The tty is interpolated into AppleScript, so `isValidTTY` is an allowlist, not
an escape — `/notify` is an HTTP endpoint, not just a hook.

### Reading Mail costs 12 seconds, once

Three measured facts drive `AppleMailConnector`, and each one was a wrong
assumption first:

- **A cold Mail is slow.** `messages of inbox whose read status is false` takes
  **12s** on the first Apple Event after Mail idles and **0.15s** warm;
  `unread count of inbox` is 0.12s either way. A slow first poll is normal —
  never report it as a broken source, and don't wrap it in a timeout that
  calls it one.
- **The Envelope Index is off limits.** `~/Library/Mail` is TCC-protected
  (`ls` → "Operation not permitted"), so the SQLite route needs Full Disk
  Access on top of a private schema. Same rejection as the Notification Center
  DB above.
- **Mail returns messages newest-first** (verified: item 1 was two months
  later than item n), which is why the 100-message cap slices
  `items 1 thru 100`. If that ever changes the cap silently starts triaging
  the *oldest* mail in the box.

Two scripting traps: properties need explicit coercion (`subject of m as text`,
not `subject of m`), and `date received as string` is locale-dependent — emit
the components and rebuild the date in Swift. Field separators are ASCII 31/30
because a subject can contain a tab or a pipe but not a control character.

Authorization failure is `errAEEventNotPermitted` (**-1743**) and looks exactly
like an empty inbox, which is the rule-5 case for this connector — see
`AppleMailConnector.explain(appleScriptError:)`. In 0.3.0 that was the missing
entitlement, not a TCC decision; see rule 2.

**Addressing a message for write-back needs the account and mailbox, not an
id.** Mail's numeric `id` is scoped to a mailbox, so the same number can mean
different messages in different accounts and a bare lookup in the unified
`inbox` is not reliably the message you meant. `MessageHandle` carries account
id + mailbox name, with the RFC Message-ID and then the bare id as ordered
fallbacks.

**Done means read.** Marking a mail row done marks it read in Mail, and clears
the flag as well when a flag is what queued it. Read is the load-bearing half:
unflagging alone leaves the message unread, so an unread-scoped source
re-queues it forever.

## Diagnostics — crashes and errors (added 2026-08-26)

`Sources/App/Support/Diagnostics/`, surfaced in **Settings › Diagnostics**.
Rule 5 turned on the app itself: a crash used to leave nothing but a menu bar
icon that had gone, and a connector failure left a red dot whose reason
vanished with the Settings window.

**No third-party SDK, no telemetry, no network.** Everything is read from
files macOS already writes and files beside the store, and leaves the Mac only
when the user presses Copy Report, Report on GitHub, or Export Diagnostics.

Four facts were measured on macOS 26.5 before any of it was written, and each
one removed a dependency someone would otherwise reach for:

- **`~/Library/Logs/DiagnosticReports` needs no Full Disk Access and no
  entitlement.** Controls: `~/Library/Mail` and `~/Library/Safari` were both
  "Operation not permitted" in the same process that read a report end to end.
  So `CrashHarvester` just reads the OS's own `.ips` — an in-process handler
  (PLCrashReporter, KSCrash) would re-derive strictly less, because a signal
  handler cannot safely allocate, while adding a binary to sign and notarize.
- **`OSLogStore.local()` needs no entitlement either** — verified from a
  **launchd-launched, Developer ID, hardened-runtime `.app`** carrying only
  our apple-events entitlement, which returned 184 entries written by
  *previous* processes. Apple's docs name `com.apple.logging.local-store`;
  that is stale for an unsandboxed app run by an admin user, and declaring an
  entitlement we cannot be granted would break signing rather than help. This
  is why breadcrumbs need no bespoke file logger. **Verify a probe's signature
  before believing it** — `codesign -dvv` must say `flags=0x10000(runtime)`;
  an unsigned probe reports cheerful passes it has not earned.
- **A `.ips` is two JSON documents, not one.** Line 1 is the header
  (`bundleID`, `app_version`, `os_version`, `timestamp`, `bug_type`); line 2
  onward is the body. Handing the whole file to a decoder fails, and reads as
  a corrupt report rather than the wrong parse.
- **The shipped binary keeps its Swift symbols** (556 `AppState` symbols in
  the installed 0.3.5 binary), so crash frames in our own code already
  resolve to function names. A dSYM adds file and line — which is why
  `notarize.sh` now archives one and `release.sh` attaches it. It cannot be
  recovered later: a dSYM is matched to a binary by UUID and a rebuild
  produces a new one. **No release before 0.3.6 has one.**

### Three traps, all found by running it rather than reading it

- **`bug_type` 309 is a crash, and the `termination.namespace` decides
  whether the indicator is worth reading.** A dyld failure's indicator
  ("Library missing") names the bug outright; a `SIGNAL` one only restates the
  signal ("Segmentation fault: 11") and costs you the frame that says *where*.
  Preferring the indicator unconditionally titled a real segfault
  "Segmentation fault: 11" until a live `kill -SEGV` showed it.
- **Never borrow a frame from another image for the crash signature.** Every
  idle Mac app is sitting in `mach_msg2_trap`, so a fallback to "topmost
  symbolicated frame" gives every unrelated crash the same title and groups
  them together. `topmostOwnSymbol` returns nil instead, and the signature
  says "sent by `<proc>`" when something killed us — a killed app did not
  crash, and the two need different investigations.
- **`xcodebuild test` runs the *app* as its test host and then kills it**,
  which leaves a run marker behind and looks exactly like a force quit. A
  plain test run wrote a false "quit unexpectedly" into the developer's own
  live diagnostics log — and Debug and Release share that one file.
  `DiagnosticsRecorder.isRunningTests` is the guard; keep it.

### The parts, and why each exists

| File | Job |
|---|---|
| `AppLog` | The one subsystem constant + a closed category set. Was seven copies of a string literal; `UnifiedLogReader`'s predicate is only honest because it is now one. |
| `CrashReportFile` | Pure parsing, signature, backtrace rendering and redaction. All `nonisolated static`, all unit-tested against a real trimmed report. |
| `CrashHarvester` | Sweeps `DiagnosticReports` **and `Retired/`** — macOS moves reports there, so a top-level-only sweep goes blind on exactly the older crashes people report. |
| `RunMarker` | The only thing that can tell a crash from a quit, and the only evidence of a run macOS wrote no report for at all (force quit, jetsam, lost power). |
| `ExceptionTrap` | `NSSetUncaughtExceptionHandler`, chained. Fills one gap — the Objective-C exception *reason* — and is **not** a crash handler. `PanelToggler`'s KVC against a private `statusItem` selector is the live example. |
| `ProblemLog` | Bounded JSONL beside the store. A tee off sentences the app already computes, with a 15-minute repeat window so a source failing every 30s writes one line, not one per poll. |
| `UnifiedLogReader` | Breadcrumbs, straight out of the unified log. |
| `DiagnosticsReport` | Assembles the export. **The single choke point where `redact` runs**, so a section added later cannot forget to. |
| `DiagnosticsRecorder` | `@MainActor @Observable`, created at App scope beside `UpdateController` and started from `init` — with `.menuBarExtraStyle(.window)` the panel's content is not built until the user first clicks, so a `.task` there would miss the launch entirely. |

**"Recorded once" and "still shown until dismissed" are two different
questions** and have two UserDefaults keys. Filtering the sweep by date meant a
crash was visible for exactly one launch and then gone — fine for a
notification, wrong for a pane whose whole job is to still have the evidence
when someone finally goes looking.

### Adding a failure path? Tee it

`ProblemLog.note(...)` is fire-and-forget, returns nothing and cannot throw, so
it changes no control flow. Existing call sites: `AppState.handle` (which
covers *every* connector, because `SyncEngine` turns any thrown error into
`ConnectorStatus.error`), launch-at-login, the journal, the agent hooks, and
`UpdateController`. Reuse the sentence the user already sees; do not write a
second one.

## Topics — one thing across several sources (added 2026-08-26)

`Sources/App/Models/Topic.swift`, `Sync/TopicMatcher.swift`, `UI/TopicRowView.swift`,
`UI/TopicEditorView.swift`. Design and the measurements behind it:
`docs/topic-grouping-plan.md`.

A topic owns **a name and an optional rule (`terms`)**. Everything else —
active, snoozed, done, pinned, high-signal, seen — is derived from its
members, so there is no second state machine. Membership is `Item.topicID`, a
plain string, matching how every other cross-entity link here works.

The measurement that decides the design: **reminders carry an issue key 0
times out of 22** in the real store, while mail does 21 of 50. So the member
that matters most in a cross-source topic is the one auto-matching can never
find — **manual membership is the primitive and auto-catch is the layer on
top**, never the reverse. `[A-Z]{2,6}-\d+` is the token that actually crosses
sources (14 topics, 118 items); a **bare `#1234` is not** and produced a false
match on the first pass over real data, so only `owner/repo#123` is admitted.

Five things that look like oversights and are not:

- **`topicID` is deliberately absent from `Store.update(_:from:)`.** That
  method refreshes nearly every field from the remote on every poll — `kind`
  was *added* to it, correctly — so anything that must survive a poll has to
  be left out by hand. `updateLeavesMembershipAlone` in `Tests/TopicTests.swift`
  is the guard; without it a poll erases the feature overnight.
- **Auto-catch runs on insert only.** Re-running it per poll would undo a
  manual removal on the next refresh — the same "explicit beats rule"
  invariant seen from the other side. Back-fill happens once, when a topic is
  created or its terms are edited, and never steals a row already filed
  elsewhere.
- **A topic below `TopicPolicy.minimumVisibleMembers` (2) renders as an
  ordinary row** carrying an "In a topic" chip. `.remoteTruth` erodes topics
  to one member routinely, and a disclosure triangle over one item is a lie.
- **An empty topic is a normal resting state, not garbage.** It is what lets
  tomorrow's matching item re-form the group, so `purge` needs age *and*
  emptiness before deleting one.
- **The badge counts a topic as one** (`Store.badgeCounts`). Brandon's call,
  2026-08-26. A badge still reading 54 while the queue shows one row would
  make the queue the liar.

### Auto-grouping folds are a view, not a record (added 2026-09-03)

`Item.groupKey` / `groupLabel` (source-authoritative: the Slack channel id,
`issue:EPD-1873`, `owner/repo`, the ntfy topic, a mail sender's address),
`SourceConfig.autoGroups` (`Bool?`, nil = the kind's default from
`ConnectorKindDescriptor.grouping`), `PanelQueue.folded`, and a "Group"
checkbox beside On / Badge / Banners in the Sources pane. Design and the
measurements behind it: `docs/auto-grouping-plan.md`.

A **fold** is a `TopicGroup` of kind `.fold`, computed by `PanelQueue` from
rows of one source that share a `groupKey`, and **never written to the
store**. That one choice is why there is no naming, no purge, no back-fill
when the checkbox flips, and why every verb a topic header answers to works
on a fold with no new code: the panel routes `D`/`E`/`S`/`U`/`C`/`⌘P`
through `selectedTopic` and does not care which kind it holds.

Four things that look like oversights and are not:

- **`groupKey`/`groupLabel` are IN `Store.update`, the opposite of
  `topicID`.** A topic is yours and a poll must not dissolve it; a channel
  label is the source's, and a poll is how a renamed channel comes to read
  correctly. `updateRefreshesGroupKey` and `updateLeavesMembershipAlone` sit
  side by side in `Tests/TopicTests.swift` and guard the two directions.
- **Folds render inside their source section, not under TOPICS, and a
  source filter keeps them.** Topics dissolve under a filter because a
  cross-source row is not an answer to "show me Slack"; a same-source fold
  is exactly that answer. `SourceGroup.rows` interleaves folds and loose
  rows by date so a fold with a fresh member rises like the row would have.
- **A row with a `topicID` is never folded** — explicit beats rule, and the
  whole invariant is one comparison in `PanelQueue.folded`. `G` on a fold
  header opens the naming card with the members, which is the path from a
  fold to a topic; there is no edit and no "ungroup", because there is
  nothing stored to edit.
- **To-do kinds are offered and default off** (`Grouping.defaultOn`). 18
  active reminders in 4 lists fold to 4 rows and a badge of 4, and a to-do
  is work rather than noise. `local`, `jsonPoller` and `fake` have no
  `Grouping` and get **no checkbox** — one that does nothing is the
  copy-volume problem in another shape.

Two connector rules: **the key is the stable id and the label the human
name** (channel id + `#name`; project URL + project name; sender address +
display name), and **no key for a row that is already the group** — a Slack
DM is `dm-<channel>`, one row per conversation, and an unnamed channel gets
nil rather than a header reading `C0AP7Q92ZPB` (`channelGrouping`). The
badge counts a fold as one (`badgeCounts(groupingSourceIDs:)`), so expect it
to drop hard the first time a busy Slack folds — measured 188 → 49 over one
week — and check that before suspecting the count.

### Batching is about motion, not throughput

`Store.markDone(uids:)` / `snooze(uids:)` / `setPinned(uids:)` do **one**
save. Four separate saves mean four `queueVersion` bumps, so one topic
dismissal animates as four staggered row collapses instead of the single
gesture `PanelMotion` exists to produce. The **write-throughs stay per item**
in `SyncEngine.writeThrough` — each source has to be told separately and each
can fail separately, so a failure is reported against the source it belongs
to.

`AppState.undoStack` is `[[String]]`: one entry per *action*, not per row.
This also fixed a main-window bug nobody had filed — dismissing five selected
rows there used to take five ⌘Z.

### Two selection concepts in the panel, on purpose

`Space` marks rows — as do ⌘-click, the hover checkbox, and **⇧↑/⇧↓**, which
mark every row the selection passes (added 2026-09-03, Brandon: *"if i hold
shift key while moving up or down, it should select each notification i tab
through"*). The Shift run is anchored where it began, so reversing shrinks it
(`PanelMarks.extendRange`); any other selection move ends the run. `E`, `S`,
`U`, `C`, `⌘P` and `G` then act on **all** of
them. Both keys were free: they fell through to type-to-filter, and they are
taken behind the same `filterText.isEmpty && !isFiltering` guard the other
letters use.

The rule that keeps this unambiguous: **the mouse acts on what it points at,
the keyboard acts on what is marked.** A row's own hover buttons are always
about that row — you are pointing at it — while the keyboard has no pointer,
so it reads the mark set when there is one and the selection otherwise. The
marks bar above the footer carries bulk buttons for the same verbs, because
that bar is the one place a click is unambiguously about the marks.

**This reverses the first build's rule, and why it reversed is the useful
part.** Marks originally drove `G` alone, because letting `E` act on them
would have meant the answer to "what does E do right now" depended on
invisible state. That objection was correct *about that build* — marking had
no affordance at all: no checkmark, no bar, Space and nothing else. Once
marking became visible the objection expired, and Brandon asked for the bulk
verbs the next day. The lesson is not that the rule was wrong; it is that **a
rule can be load-bearing only because of a UI gap, and has to be revisited
when the gap closes.**

Bulk verbs **consume the marks** (`PanelView.afterBulk`) — except a refused
`C`, which leaves them, so a mixed set isn't silently thrown away along with
the error. `U` and `⌘P` **normalize** a mixed set rather than flipping each
row, or a mixed set would stay mixed forever.

`D` is now a level rather than a toggle, with two at-most-one flags:
`openTopicID` (which topic shows its members) and `isFullyExpanded` (which row
shows its whole message). A topic closes when the selection leaves it, same
discipline as a full expansion. Esc peels: card → full message → open topic →
marks → filter → archive → dismiss.

The naming card is an **overlay, not a `.sheet`** — the panel is a
`MenuBarExtra(.window)` whose window is not key by default (`PanelKeyboardFocus`),
and a sheet there inherits every one of those problems. While it is up, the key
monitor returns `false` for everything but Esc so its text fields get the keys.

**`.fill(.background)` is TRANSLUCENT in the panel.** The panel is a vibrant
surface, so the `.background` shape style resolves there to something you can
see straight through — the first build of the naming card let the entire queue
show through it and shipped unreadable. Anything floating over the queue must
bring its own opaque ground: `Color(nsColor: .windowBackgroundColor)`. Nothing
catches this in a build, in tests, or in an `ImageRenderer` sheet (which has no
vibrant surface to get wrong) — only opening the panel does.

**And a keyboard-only gesture has no discoverability at all.** Marking shipped
as `Space` and nothing else, and the first person to look for multi-select
reported there was no way to do it. Anything new that is not a letter on an
existing hover button needs a *visible* affordance: `ItemRowView.marker` turns
the unseen dot into a clickable checkbox on hover (`MarkBox` — a
continuous-corner square, because the circle it first shipped as read as a
radio button, Brandon 2026-09-03), ⌘-click marks (the platform idiom), and
`MarksBar` names the count and the keys while any row is marked. Copy that
pattern rather than adding a second invisible key.

### Marking has to be cheap, and two things made it not (2026-09-03)

Brandon: *"the bulk select feature … is very sluggish"*. Two causes, one
measured and one not:

- **A double-tap declared ahead of a single tap holds every single click for
  the double-click interval** — 0.5s by default on this Mac
  (`NSEvent.doubleClickInterval`) — so SwiftUI can be sure the second click
  is not coming. Row selection had carried that since the first commit and
  nobody noticed, because the panel is driven from the keyboard; ⌘-click
  marking was the first mouse-heavy flow through it. Rows now attach **one**
  tap gesture and read `NSApp.currentEvent?.clickCount` for the double —
  select on the first click, open on the second. *Not* measured here: SwiftUI
  tap gestures ignore synthetic `NSEvent`s posted in-process (a `Button` in
  the same window fires, `onTapGesture` never does), so with no Accessibility
  grant for Claude Code the delay is known from SwiftUI's behaviour, not
  timed on this machine. If double-click-to-open ever stops working, this is
  the line to suspect.
- **`marks` was a `Set` in `@State` on `PanelView`**, so every toggle re-ran
  the whole panel body — queue rebuilt, filter bar, footer and every visible
  row re-evaluated. The queue build itself measured only ~1ms at his 186
  items, so this was the smaller half. `PanelMarks` is `@Observable` and the
  panel body never reads its contents; rows and `MarksBar` do, through the
  environment. Keep it that way: a `marks.uids` read anywhere in
  `PanelView.body` silently brings the full re-render back.

## Already exists — do not rebuild

- **Per-source badge toggles** (`SourcesPane`, honoured in `AppState`) — the
  badge *style* picker in General is a separate control.
- **Keyboard nav** ↑/↓/⏎/E/S/⌘P and ←/→ source cycling in the panel. `C`
  completes a to-do row (panel, main window, row button, archive) and is
  refused out loud on any other source — see the to-do section below.
- **Rows that open on selection** (`UI/ExpandingText.swift`) — the selected
  row grows to `RowExpansion.titleLines`/`bodyLines` and every other row
  stays on one line. Both clamps are laid out at once and cross-faded behind
  a clipped frame; animating `lineLimit` directly re-wraps the glyphs every
  frame and pops the ellipsis, and clipping the open copy alone loses the
  "…" that says there is more. Connector snippet caps
  (`SlackConnector.snippetLimit`, `LinearConnector.snippetLimit`) exist to
  keep something behind that ellipsis — a cap at the visible line makes the
  expansion reveal whitespace. **Since D (below) the target changed from "a
  paragraph" to "the message": Slack's cap is 4,000, and Linear's is still
  320, which means D on a long Linear comment still stops at an ellipsis it
  cannot get past.**
- **D on the selected row shows the whole message** — a third state on the
  same view (`ExpandingText.isFull`), owned by one `isFullyExpanded` flag on
  `PanelView` so it can only ever be true of one row and closes whenever the
  selection moves. Three things it deliberately does:
  - The unlimited copy is laid out for the **selected row only**, and only
    once the 4-line copy has been measured. Always laying it out means laying
    out every character of every body on screen; laying it out before the
    paragraph is measured makes it the clamp's natural-height fallback, so a
    row scrolling in already selected paints its whole message for a frame.
  - It is **measured before the press**, not after. A height that arrives
    from a geometry callback lands on the pass *after* the transaction, so
    the row jumps open instead of animating.
  - `select(_:)` in `PanelView` is the only way the selection moves, because
    it is what closes the expansion. Resetting from an `onChange` observer
    instead breaks the row's own D button: the click selects and expands in
    one event, and the observer runs after both.

  **A connector that stores no body makes D look broken, and that is the
  first thing to check.** Reported 2026-08-23 as "expansion doesn't work for
  Slack saved messages"; it was not the UI. `makeSaveItem` put the *message*
  in the title, cut to 80 characters, and left `snippet` nil — so there was
  no body to reveal and the rest of the message never reached the store. Two
  general lessons:

  - **The title is not a place to put a preview.** Every other kind titles
    the row with what happened and puts the text in `snippet`; the one kind
    that didn't was the one kind D could not open. `Store.update` refreshes
    `title` and `snippet` like every other field, so fixing a shape like
    this repairs existing rows on the next poll — nothing to re-save.
  - **`ExpandingText.clampedPrefix` is why a 4,000-char cap is affordable.**
    The two clamped copies are laid out for *every row on screen* and `Text`
    lays out whatever string it is handed, so they get a prefix with enough
    headroom that the clamp is still what truncates. Only the unlimited copy
    — the selected row alone — is handed the whole string. Raise a connector
    cap without this and every row pays for text that is clipped away.

  **Two Slack seeding facts, both measured 2026-08-23 after "I pasted the
  token and nothing happened":**

  - **`reactions.list` will not paginate past 100 items.** `limit=100` failed
    on page 1; `limit=25` failed on page 4; both had scanned exactly 100. The
    error is `internal_error` — Slack's own fault code, saying nothing about
    scopes — so this had to be measured, not reasoned about. The backfill can
    only ever see the 100 most recent reactions; re-applying the emoji is the
    only way to reach an older save, because that takes the live
    `reaction_added` path.
  - **A paged loop must `break`, not `return`.** `seedEmojiSaves` bailed with
    a bare `return`, discarding every save read from earlier pages — so a
    transient failure on page 2 threw away page 1 on *every* connect, and the
    feature looked permanently dead rather than occasionally short. Emitting
    a partial list is safe here only because this connector never emits
    `.snapshot`; check that before doing the same elsewhere.

  **And `seedEmojiSaves` was the second instance of the downstream-of-`seed()`
  trap.** It sat after a walk of 377 DM conversations at ~50 `conversations.info`
  per minute — so one cheap call was stuck behind ten minutes of expensive
  ones, and re-registering the source to "pick up my saves" restarted the walk
  and made it *further* away. It now runs first. When a user says a Slack
  feature does nothing, check where in `seed()` it lives before anything else.

  Known and deliberate: `truncate` flattens newlines to spaces, so a
  multi-paragraph message opens as one run of text. Fixing that is a real
  design tradeoff, not an oversight — the flattening is what keeps a closed
  one-line row scannable, and per-copy newline handling would reflow the
  glyphs mid-animation, which is the thing `ExpandingText` exists to avoid.
- **Journaling to Obsidian** (`Journal/JournalWriter.swift`) — an output, not a
  source; needs Full Disk Access for iCloud vault paths.
- Saving a source in the editor already calls `bootstrapConnectors()`, so
  connectors reload without an app restart.
- **A full main window** (`UI/MainWindow/`), opened via `⌘0` or the panel
  footer — same queue, every triage action mirrored as a real `Commands` menu
  item (`MainWindowCommands.swift`) via `@FocusedValue(\.triageActions)`, not
  a second implementation of triage.
- **App Intents / Siri Shortcuts** (`Intents/QueueIntents.swift`) — get,
  count, snooze, mark-done, all against the same `Store`.

## Distribution (Developer ID + notarization)

The app needs **no App ID registration and no provisioning profile**. Those only
authorize entitlements Apple must bless — iCloud, App Groups, Push, Keychain
Sharing — and this app uses none. (**True for Developer ID only.** The Mac App
Store requires all three — App ID, embedded profile, Apple Distribution cert —
plus a mandatory App Sandbox; that route was audited and declined, PLAN §2.1.8.) It is unsandboxed, so network access, the
loopback listener and the Keychain all work without entitlements.

Release ships **exactly one entitlement** — `com.apple.security.automation.apple-events`
(see the AppleScript rule below; it needs no App ID or profile) — plus a
hardened runtime and a secure timestamp. The last two were wrong at first and
neither was visible in a normal build:

- Xcode injects `com.apple.security.get-task-allow` (the debugger-attach
  entitlement) unless told not to. Notarization rejects it.
- Xcode signs local builds `--timestamp=none`. Notarization requires a secure
  timestamp. The embedded `inchill` had one — its post-build script asks
  explicitly — while the bundle around it did not.

Both are fixed in `project.yml` under `settings.configs.Release`. Check an
installed build before trusting it, because neither shows up as a build failure:

```bash
codesign -dvv "/Applications/Inbox & Chill.app" 2>&1 | grep -E "Timestamp|flags="
codesign -d --entitlements - "/Applications/Inbox & Chill.app"   # expect ONLY apple-events
codesign -d --entitlements - "/Applications/Inbox & Chill.app" 2>/dev/null | grep -c get-task-allow  # expect 0
codesign --verify --deep --strict "/Applications/Inbox & Chill.app"
```

**"No Keychain password item found for profile" does not mean the credentials
were deleted.** `store-credentials` defaults to the iCloud **"Local Items"
(data-protection) keychain**, and three facts follow that have now cost two
separate investigations:

- **`security` cannot enumerate that keychain at all.** A sweep of all ~400
  generic passwords in `login.keychain-db` finding nothing is *not* evidence of
  deletion — it is evidence you searched the wrong store.
- **The attributes are not the obvious ones.** The item matches on `labl` =
  `com.apple.gke.notary.tool` with `acct` =
  `com.apple.gke.notary.tool.saved-creds.<profile>`. Searching service
  `com.apple.gke.notary.tool` or account `<profile>` misses it even in the
  right keychain.
- **notarytool prints the same message when it merely cannot read the item.**

**The trigger, identified 2026-08-21: sleep.** The Local Items keychain locks
when the Mac sleeps, and a **DarkWake does not unlock it** — that needs the
user's login credential. So a non-interactive read during a dark-wake window
fails, and the same command succeeds again once someone touches the machine.
Caught by lining the two up: reads succeeded at 19:58 local, failed at 22:45,
and `pmset -g log` showed `Entering Sleep state 'Maintenance Sleep'` at
22:32/22:36 with a `DarkWake from Deep Idle` at 22:44:45. On battery this
happens every few minutes while idle, which is why the credentials seem to come
and go on their own. Nothing is being deleted; **an unattended release run is
simply unreliable.**

The file-based login keychain is *not* affected — `security show-keychain-info`
reported `no-timeout` (unlocked) at the same moment the Local Items read was
failing. That is the argument for pinning the profile there with `--keychain`:
it survives sleep, so a release can run unattended.

The only reliable check is notarytool itself:

```bash
xcrun notarytool history --keychain-profile inbox-and-chill --verbose
```

`Found Keychain password item` means they exist — re-run whatever failed.
To see which keychain holds it, force the file one with
`--keychain "$HOME/Library/Keychains/login.keychain-db"`: if that fails while
the default succeeds, the item is in Local Items. Storing with `--keychain`
pins it to the file keychain instead, where `security` can see it and Time
Machine backs it up.

`scripts/notarize.sh` does the rest: preflights the four things above, submits,
staples, and writes `dist/InboxAndChill.zip`. Its credential check
retries once and explains the above rather than asserting the credentials are
gone. It needs credentials
stored once via `notarytool store-credentials` — a person has to do that, it is
not scriptable. `scripts/notarize.sh --preflight-only` checks a build is
submittable without any credentials at all.
`spctl -a` reporting "rejected — Unnotarized Developer ID" is expected until
then and is harmless locally, since Gatekeeper only evaluates quarantined apps.

**`scripts/release.sh` is the layer above it**: preconditions (on `main`, clean
tree, in sync with `origin`, tag and release not already taken) → `notarize.sh`
→ annotated tag → `gh release create` with the zip attached. Version comes from
`MARKETING_VERSION` in `project.yml`, the single source of truth — bump and
commit it before running.

It **always rebuilds and re-notarizes** rather than attaching whatever sits in
`dist/`. That is the whole point: before it there were no tags and no releases,
so nothing recorded which source a zip came from, and `dist/` was holding a
0.3.1 zip that predated two commits on `main`. A tag whose artifact was built
from different code is worse than no tag.

**The repo went public on 2026-08-21**, which was the last precondition for
Sparkle. Release assets now download with no credentials (verified: the
`v0.3.2` zip returns 200 anonymously). The earlier note here — that Sparkle was
inert because a private repo 404s for strangers — described a state that no
longer holds.

**Sparkle still does not work yet, for a different reason: nothing has shipped
since it was wired in.** `v0.3.2` is tagged at `21c231b`, before `5a9ce81`
(Sparkle) and `806b42d` (the signing key), so the only published build has no
Sparkle in it at all — no `UpdateController`, no `SUFeedURL`, no
`SUPublicEDKey`. It does not fail to find an update; it never looks. And
`appcast.xml` has never been generated, so the feed URL 404s.

The next release fixes both at once, and is a one-time manual install for
anyone on 0.3.2. **`docs/releasing.md` is the runbook** — read it before
cutting a release. See also PLAN §2.1.9.

**That last point cuts both ways: `spctl` on a copy you built is not a test.**
Gatekeeper skips unquarantined apps entirely, so a local "accepted" says
nothing about what a downloader sees. Test the artifact the way it will
arrive — extract the dist zip and mark it quarantined first:

```bash
ditto -x -k dist/InboxAndChill.zip /tmp/gk && \
  xattr -w com.apple.quarantine "0083;00000000;Safari;" "/tmp/gk/Inbox & Chill.app" && \
  spctl -a -vvv --type execute "/tmp/gk/Inbox & Chill.app"
```

Expect `accepted` with `source=Notarized Developer ID`.

**Stapling is separate from being notarized.** `notarize.sh` staples the build
product, not `/Applications`. An unstapled copy still passes *while the machine
can reach Apple* — `stapler validate` is the only thing that catches it, and the
failure only shows up offline:

```bash
xcrun stapler validate "/Applications/Inbox & Chill.app"
```

`install-local.sh` now staples automatically when a ticket exists, so a fresh
install matches what ships. **But any rebuild re-signs, and the ticket belongs
to the old signature** — so a locally rebuilt dev build cannot be stapled and
reports `Unnotarized Developer ID` until it is notarized again. That is normal
between releases. The only sequence that produces a stapled install is
`notarize.sh` followed by `install-local.sh` with no source change in between.
Symptom of getting it wrong: `stapler staple` fails with
"Could not find base64 encoded ticket in response".

## In-app updates (Sparkle) — three traps, all silent

Sparkle 2.9.6, added 2026-08-21. `UpdateController` owns it; the feed is
`appcast.xml` at the repo root, served by raw.githubusercontent.

**It could not work while the repo was private, and that was the mechanism,
not a bug.** Sparkle fetches the appcast and then the zip with no credentials,
and a private repo's release assets 404 for everyone but a collaborator. It
*does* have an `httpHeaders` property — so "Sparkle can't send a token" is
wrong — but a token shipped inside a downloadable app is public by
construction. That constraint is now satisfied: the repo went public on
2026-08-21. What remains is that no Sparkle-carrying build has been released
yet, and no `appcast.xml` exists — `docs/releasing.md` covers both. See PLAN
§2.1.9.

### 1. `INFOPLIST_KEY_<anything>` only works for keys Xcode already knows

`INFOPLIST_KEY_SUFeedURL` built, linked, signed and shipped a bundle with **no
`SUFeedURL` in it**, with no warning at any stage — Sparkle would simply have
had no feed to read. Xcode's `INFOPLIST_KEY_*` mechanism honours an allowlist
and drops everything else on the floor.

So the app now uses an **XcodeGen-generated `Info.plist`** (`info:` in
project.yml; the output is gitignored like the `.xcodeproj`). One trap inside
that trap: XcodeGen's plist defaults hardcode `CFBundleShortVersionString` to
`1.0` and `CFBundleVersion` to `1`. Left alone they pin every build to version
1.0 — breaking the About pane, the name `notarize.sh` gives the dist zip, and
Sparkle's "is this newer?" comparison. Both are mapped explicitly to
`$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`. So is
`LSMinimumSystemVersion`, which Xcode injects only into plists it generates
itself, and which Sparkle reads to set `sparkle:minimumSystemVersion`.

**Verify against the built plist, never the build log:**

```bash
plutil -extract SUFeedURL raw "/Applications/Inbox & Chill.app/Contents/Info.plist"
```

### 2. Xcode leaves Sparkle's nested helpers ad-hoc signed

`Sparkle.framework` is not one binary. It carries `Autoupdate`, `Updater.app`
and two XPC services *inside* it, and Xcode's embed step re-signs only the
framework bundle — leaving all four **ad-hoc signed, with no team identifier
and no secure timestamp**. Verified on a Release build, 2026-08-21.

Nothing catches it on the way past. The build succeeds, `codesign --verify
--deep --strict` **passes** (an ad-hoc signature is a valid signature), and the
app runs and self-updates perfectly well locally. Notarization is the first
thing that objects, and it objects a long way from the cause — the same shape
as the `get-task-allow` and missing-timestamp bugs above.

Fixed by project.yml's *Re-sign Sparkle's nested helpers* phase, which signs
inside-out because sealing an inner item invalidates every seal around it.
`notarize.sh`'s preflight now checks each nested item individually, and that is
the regression guard. `--verify --deep` is not, and never was.

```bash
codesign -dvv "<app>/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate" 2>&1 \
  | grep -E "adhoc|Developer ID|Timestamp="
```

### 3. An unsigned appcast entry looks exactly like a working one

`generate_appcast` signs an enclosure **only when the app inside that archive
declares `SUPublicEDKey`**. A build made before the key existed produces an
entry with no `sparkle:edSignature` — which Sparkle then refuses, so nobody
updates and nothing says why. `appcast.sh` fails outright when the newest entry
is unsigned, and names the script that fixes it.

Two more facts about the feed:

- **`CURRENT_PROJECT_VERSION` must increase every release.** It is what Sparkle
  compares, not `MARKETING_VERSION`. `release.sh` refuses to tag otherwise;
  without that check a release is a silent no-op for every existing install.
- **GitHub release URLs embed the tag**, and `generate_appcast` can only prepend
  one fixed prefix, so `appcast.sh` inserts `v<version>/` per enclosure
  afterwards. That is safe because `edSignature` signs the archive bytes, not
  the URL. It is idempotent, and it refuses to write a feed with an un-tagged
  URL left in it. The tag comes from each item's `sparkle:shortVersionString`,
  **not** from the filename.
- **The zip is `InboxAndChill.zip` in every release — no version in the name**
  (changed 2026-08-26), so
  `releases/latest/download/InboxAndChill.zip` is a link that survives
  releases. Two things had to be checked before doing it, and both hold:
  `generate_appcast` keys entries by version rather than by file, so a
  same-named archive does **not** clobber the previous release's entry
  (measured: two rounds with a fixed name kept both items); and the tag
  rewrite in `appcast.sh` now reads the version from the item instead of the
  name.
- **The DMG is `InboxAndChill.dmg` too**, same date and same reason —
  `releases/latest/download/InboxAndChill.dmg` is the link a *person* clicks,
  so it is the one most worth keeping stable. The cask is unaffected: its
  `url` still interpolates `v#{version}/`, and `version` + `sha256` still pin
  the exact bytes, so brew downloads the release the cask names.
- **The dSYM keeps its version, deliberately.** It is the one artifact that
  accumulates in `dist/` across releases, and nothing inside it says which
  build it belongs to — it is matched to a binary by UUID. An unversioned
  dSYM would be a file you cannot attribute.
- **Two accidental checks were lost, and one replaced both.** A build whose
  version disagreed with `project.yml` used to surface as
  `dist/InboxAndChill-<version>.zip` (or `.dmg`) being missing after
  `notarize.sh` — that is the stale-`.xcodeproj` failure that cost the first
  attempt at cutting 0.4.0. Fixed names cannot fail that way, so `release.sh`
  reads `CFBundleShortVersionString` out of the zip and compares it before
  pushing the tag. Read it by the **exact** path: `unzip -p "$ZIP"
  "*/Contents/Info.plist"` matches five plists (Sparkle's `Updater.app`, both
  XPC services, the KeyboardShortcuts bundle, and the app's own **last**),
  because unzip's wildcards cross `/`.
  The other lost check was `homebrew-cask.sh`'s: `dist/dmg/InboxAndChill.dmg`
  no longer proves which version it holds. Its published-asset comparison
  catches a stale one on every path that publishes — but `--local-only` skips
  that, so a cask written that way proves nothing until the full run.

### The signing key lives in the *login* keychain

`generate_keys` stores it in the file-based login keychain — not the iCloud
"Local Items" keychain that has twice made the notary credentials look deleted.
So `security` can see it, Time Machine backs it up, and **it does not lock when
the Mac sleeps**. Losing it is unrecoverable, though: existing installs trust
only the public key baked into the build they are already running. Back it up.

### Releases build clean now

`notarize.sh` runs `clean build`. An incremental Release build can run
`ExtractAppIntentsMetadata` *after* codesign, rewriting
`Contents/Resources/Metadata.appintents/extract.actionsdata` and breaking the
seal; preflight then refuses to submit, a long way from the cause. Observed
2026-08-21.

## Homebrew — one cask, two updaters, one checksum that must be right

`brew install --cask brandonlucasgreen/tap/inbox-and-chill`. Full story in
`docs/homebrew.md`; the parts that bite:

- **Edit `packaging/homebrew/inbox-and-chill.rb`, never the tap's copy** — the
  tap is overwritten on every release by `scripts/homebrew-cask.sh`, which
  `release.sh` calls after the GitHub release exists.
- **`auto_updates true` does not mean brew leaves the app alone.** Current brew
  (`Cask#auto_updates_bundle_outdated?`, checked against 6.0.18) compares the
  **installed bundle's Info.plist**, not its own install record, and upgrades by
  default with no `--greedy`. Sparkle and brew therefore cannot fight — whoever
  is first wins, the other no-ops. The older "brew skips auto_updates casks"
  advice is stale and was wrong here once already.
- **Never hand-write the sha256.** A cask whose checksum disagrees with the
  published asset fails for *every* user at once, and brew reports it as a
  checksum mismatch — reads like a corrupt download, not a stale cask. The
  script downloads the release asset and compares before pushing, and refuses
  otherwise. Rule 5, applied to a file that lives in another repo.
- **The cask step is deliberately non-fatal in `release.sh`.** The tag, release
  and feed are already public by then; a missing tap prints a catch-up command
  rather than failing a release that shipped.
- `homebrew/cask` proper is out of reach and not the goal: self-submitted repos
  need 90 forks / 90 watchers / 225 stars (`GITHUB_NOTABILITY_THRESHOLDS`, ×3).

## Working in a git worktree

Bash `cd` lands in the primary checkout and stays there, so edits intended for a
worktree silently land on `main` instead. **Before any commit, run
`git rev-parse --abbrev-ref HEAD` and `git status --short` and confirm which
checkout you are in.** A clean `git status` in the worktree you thought you were
editing is the tell.

When sessions run in parallel: insert new test suites **mid-file** rather than
appending (two sessions appending to `Tests/UnitTests.swift` is a guaranteed
conflict), and `git diff origin/main -- <path>` before committing — another
session may already have landed your change.
