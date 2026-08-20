# Inbox & Chill — working notes for agents

Native macOS menu bar app (macOS 15+, SwiftUI + SwiftData) that aggregates one
triage queue from Slack, Linear, GitHub, ntfy, and local producers
(the `inchill` CLI, Claude Code hooks).

`PLAN.md` is the design source of truth. This file is the operating manual:
the things that have actually bitten, and the conventions to keep.

## Commands

```bash
xcodegen generate                                        # after editing project.yml
xcodebuild -project InboxAndChill.xcodeproj -scheme InboxAndChill -configuration Debug test
scripts/install-local.sh                                 # Release → /Applications → launch
```

Tests are Swift Testing (`@Test` / `#expect`), in `Tests/`.

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

**Logging: `log show` does not work for this app.** It returns nothing for
subsystem `lol.bgreen.inboxandchill` even at `.error` level. Use a live stream
and restart the app underneath it:

```bash
log stream --predicate 'subsystem == "lol.bgreen.inboxandchill"' --info --debug --style compact
```

Put the predicate in a script rather than inline — quoting it through a shell
wrapper fails with "too many arguments". This cost several cycles of believing
code wasn't running when the logging simply wasn't reaching the terminal.

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

### 3. Quote every path you hand to a shell

The bundle is `Inbox & Chill.app`. A shell reads the `&` as a background-job
separator and silently splits the command in two — this killed the Claude Code
hooks once already. `ClaudeCodeIntegration.shellQuoted` exists for this; use it
for any hook, script, or `sh -c` string. When patching JSON written by
Foundation, remember `/` arrives escaped as `\/`.

To debug a hook that "silently doesn't fire", run the *stored command string*
the way the harness does — `sh -c "$CMD"` — not the binary with your own
quoting. The latter hides the bug.

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

## Already exists — do not rebuild

- **Per-source badge toggles** (`SourcesPane`, honoured in `AppState`) — the
  badge *style* picker in General is a separate control.
- **Keyboard nav** ↑/↓/⏎/E/S/⌘P and ←/→ source cycling in the panel.
- **Rows that open on selection** (`UI/ExpandingText.swift`) — the selected
  row grows to `RowExpansion.titleLines`/`bodyLines` and every other row
  stays on one line. Both clamps are laid out at once and cross-faded behind
  a clipped frame; animating `lineLimit` directly re-wraps the glyphs every
  frame and pops the ellipsis, and clipping the open copy alone loses the
  "…" that says there is more. Connector snippet caps
  (`SlackConnector.snippetLimit`, `LinearConnector.snippetLimit`) exist to
  keep something behind that ellipsis — a cap at the visible line makes the
  expansion reveal whitespace.
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
Sharing — and this app uses none. It is unsandboxed, so network access, the
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

`scripts/notarize.sh` does the rest: preflights the four things above, submits,
staples, and writes `dist/InboxAndChill-<version>.zip`. It needs credentials
stored once via `notarytool store-credentials` — a person has to do that, it is
not scriptable. `scripts/notarize.sh --preflight-only` checks a build is
submittable without any credentials at all.
`spctl -a` reporting "rejected — Unnotarized Developer ID" is expected until
then and is harmless locally, since Gatekeeper only evaluates quarantined apps.

**That last point cuts both ways: `spctl` on a copy you built is not a test.**
Gatekeeper skips unquarantined apps entirely, so a local "accepted" says
nothing about what a downloader sees. Test the artifact the way it will
arrive — extract the dist zip and mark it quarantined first:

```bash
ditto -x -k dist/InboxAndChill-<version>.zip /tmp/gk && \
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
