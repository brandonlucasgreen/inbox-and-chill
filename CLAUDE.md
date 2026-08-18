# Inbox & Chill — working notes for agents

Native macOS menu bar app (macOS 15+, SwiftUI + SwiftData) that aggregates one
triage queue from Slack, Linear, GitHub, Campsite, ntfy, and local producers
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

## The five rules that keep being learned the hard way

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

mtime and size are not evidence. A behavioural test that "fails" is very often a
stale binary.

### 2. Quote every path you hand to a shell

The bundle is `Inbox & Chill.app`. A shell reads the `&` as a background-job
separator and silently splits the command in two — this killed the Claude Code
hooks once already. `ClaudeCodeIntegration.shellQuoted` exists for this; use it
for any hook, script, or `sh -c` string. When patching JSON written by
Foundation, remember `/` arrives escaped as `\/`.

To debug a hook that "silently doesn't fire", run the *stored command string*
the way the harness does — `sh -c "$CMD"` — not the binary with your own
quoting. The latter hides the bug.

### 3. Read the verdicts this repo already recorded

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

### 4. Silent failure is this project's recurring bug class

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

### 5. Put logic in `nonisolated static` pure functions

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

## Connectors

| Kind | Transport | Capabilities | Notes |
|---|---|---|---|
| `linear` | GraphQL poll 30s | markDone, remoteSnooze, remoteTruth | Per-type inline fragments; `DocumentNotification` has no `document` relation (resolved by a second `documents(filter:)` pass). `Notification.subtitle` is the comment **body**, not a name. |
| `github` | REST poll | markDone, remoteTruth | Classic PAT only (OAuth tokens rejected). Paginates; `participating=true` by default. |
| `slack` | Socket Mode + poll | markDone, remoteTruth, push | User token `xoxp-` required; app-level `xapp-` optional (adds channel mentions). Keyword Watch polls `search.messages` — the only way to see a channel you're not in. |
| `campsite` | REST poll | markDone, remoteTruth | Self-hosted. v1 accepts Bearer Doorkeeper tokens; v2 has no notifications endpoint. Currently unconfigured. |
| `ntfy` | WebSocket | push | No remote read-state; items die by explicit done. `since=<id>` is exclusive-after. |
| `local` | HTTP listener | push | `inchill` CLI + Claude Code hooks. Push-only: it sees only what a hook POSTs. |

## Already exists — do not rebuild

- **Per-source badge toggles** (`SourcesPane`, honoured in `AppState`) — the
  badge *style* picker in General is a separate control.
- **Keyboard nav** ↑/↓/⏎/E/S/⌘P and ←/→ source cycling in the panel.
- **Journaling to Obsidian** (`Journal/JournalWriter.swift`) — an output, not a
  source; needs Full Disk Access for iCloud vault paths.
- Saving a source in the editor already calls `bootstrapConnectors()`, so
  connectors reload without an app restart.

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
