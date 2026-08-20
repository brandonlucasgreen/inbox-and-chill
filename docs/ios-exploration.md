# Inbox & Chill on iOS — exploration (2026-08-20)

> Status: **exploration, nothing built.** No code in this repo has been changed.
> Everything below about the existing codebase was read out of it; everything
> about Apple's platform rules is stated from knowledge and flagged in §9 where
> it needs verifying before anyone leans on it.

The question: could Inbox & Chill work as an iOS/iPadOS app — the same triage
queue, touch instead of keyboard, as a "smarter notifications inbox" for the
SaaS apps you connect to it?

**Verdict: yes, and it's a smaller job than it looks — but it is a *companion*,
not a port, and one design promise has to change or you need a server.**

The engine ports. The liveness model does not. Everything hard about this
follows from that one sentence.

---

## 1. What the audit actually says

`Sources/App` is ~11,100 lines. Split by portability:

| | Lines | Fate on iOS |
|---|---:|---|
| `Models/` | 174 | Ports unchanged |
| `Sync/` (Connector, SyncEngine, Store, Catalog) | 809 | Ports unchanged |
| `Support/Keychain.swift` | 175 | Ports; **one attribute must change** (§3.3) |
| `Connectors/Linear/` | 671 | Ports unchanged — best-behaved connector |
| `Connectors/GitHub/` | 260 | Ports unchanged — best-behaved connector |
| `Connectors/{Ntfy,JSONPoller,Fake}` | 474 | Port unchanged (ntfy loses its socket, §3.2) |
| `Connectors/Slack/` | 1,695 | Compiles; **behaves wrong** (§3.2) |
| `Journal/` | 283 | Logic ports; the Obsidian *destination* doesn't (§5) |
| `Intents/` | 254 | Ports, and is worth *more* on iOS |
| **Portable subtotal** | **~4,800** | |
| `Connectors/Local/` (listener, Claude Code, tty) | 900 | **Delete.** No CLI, no terminal, no background listener |
| `Sources/CLI/` | 353 | **Delete** (stays in the Mac target) |
| `UI/` | 4,224 | **Rewrite** — but see below |
| `AppState` + `InboxAndChillApp` | 871 | Split: ~60% is portable logic, the rest is menu-bar/AppKit |
| `Tests/` | 2,697 | **Ports nearly unchanged** |

Two findings worth pulling out of that table:

**The test suite survives.** Rule 5 in `CLAUDE.md` ("put logic in `nonisolated
static` pure functions") turns out to have been an accidental portability
strategy. 2,700 lines of Swift Testing coverage calls into pure static helpers,
not into AppKit, so it keeps working against a shared core. That is the single
biggest reason this is cheap.

**A quarter of the UI is already cross-platform.** `ItemRowView`, `SnoozeMenu`,
`FilterBar`, `PanelQueue`, `PanelHint`, `TriageActions` and
`MainWindowCommands` — 1,056 lines — import only SwiftUI/SwiftData, no AppKit
at all. `ArchiveView` and `SettingsView` touch AppKit on exactly one line each
(`NSWorkspace.shared.open`, which is `@Environment(\.openURL)` on both
platforms). The genuinely Mac-bound UI is the panel chrome, the `NSEvent` key
monitors, `NSPasteboard`, window activation, and `ExpandingText`'s `NSFont`
measuring — real work, but it's the shell, not the list.

So: **the engine and its tests come along; the app around them is new.**

---

## 2. The one thing that doesn't port: liveness

`SyncEngine.drive()` is a `while !Task.isCancelled { poll; sleep(interval) }`
loop, and for push connectors a `while { await connector.run(emit:); sleep 5 }`
loop. Both work because a menu bar app is *always running*. On iOS neither
does:

- The process is suspended seconds after you background it. Both loops stop
  mid-`await` and resume whenever the app is next foregrounded.
- `BGAppRefreshTask` is **opportunistic, not periodic** — iOS decides, from
  your usage patterns, typically a handful of times a day with seconds of
  runtime. It is not a 30-second poll and no amount of asking makes it one.
- Long-lived WebSockets die on suspend. Slack Socket Mode and ntfy's socket
  exist only while the app is on screen.
- `startMaintenanceIfNeeded()` — the 30-second snooze-wake sweep and daily
  purge — can't run either.

That last one has a **better** answer on iOS, not a worse one: schedule a
`UNNotificationRequest` with a calendar trigger *at snooze time*, and cancel it
if the item is done first. iOS fires it whether or not the app is running, with
no polling, fully offline. Decision §2.1.5 ("a waking item always banners") is
one of the few things that gets *more* reliable on the phone. Do this on the
Mac too, honestly.

Everything else about liveness is a loss, and it forces a choice.

---

## 3. Three real blockers

### 3.1 Freshness — and the badge that lies

Without a server, the iOS queue is only as fresh as your last visit. `refreshNow()`
on foreground gets you a current queue *while you're looking at it*; between
opens, the app-icon badge is a snapshot of whenever iOS last felt generous.

This collides head-on with rule 4 in `CLAUDE.md`: **a failure the user cannot
see is worse than a crash.** A stale badge is exactly that failure — it reads
as authoritative and isn't. Mitigations, in order of honesty:

1. Put "as of 14:02" in the list header, always visible, never hidden behind a
   pull gesture.
2. Never badge from a snapshot older than some threshold — show a dot or a
   "?" rather than a confidently wrong number.
3. Use a **WidgetKit** widget as the real badge surface. Widgets get their own
   refresh budget, separate from `BGAppRefreshTask`, and a widget saying
   "3 waiting · 12m ago" is honest in a way a home-screen badge cannot be.

Worth saying plainly, because it decides everything downstream: **your stated
pitch — "an inbox instead of iOS notifications, which get lost" — only fully
holds if the phone app is *fresher* than the apps it replaces, and without a
relay it structurally can't be.** The v1 that needs no infrastructure is a
different, still-good pitch: *one place to sweep on purpose, instead of eleven
apps.* Email, not paging. Which pitch you want determines whether §4's
infrastructure is optional.

### 3.2 Slack is the iOS-hostile connector

Everything else polls a stateless endpoint and doesn't care that the process
died. Slack does care, in three compounding ways:

- `SlackConnector` **deliberately never emits `.snapshot`** (documented in its
  header, and in `CLAUDE.md`): mentions exist only in its in-memory record of
  witnessed Socket Mode events, and emitting a snapshot on reconnect would
  archive them all. On the Mac, reconnects are ~10 minutes apart. On iOS,
  "reconnect" is *every single app launch*. The connector's memory is
  load-bearing state living in the one place iOS destroys most often.
- `seed()` walks every conversation in the workspace and takes **minutes** on a
  large one. On iOS that's longer than a whole foreground session.
- Socket Mode itself is foreground-only, so channel mentions — the thing the
  `xapp-` token exists for — arrive only while you're staring at the app.

None of this is fatal, but it's a genuine design pass, not a recompile: Slack's
cursors and witnessed-mention set would have to persist (the `Store` already
survives launches; it's the *connector's* memory that doesn't), and `seed()`
would need to become incremental against a saved cursor. Budget real time here,
and ship the phone app without Slack first.

ntfy degrades gracefully by comparison — its `?poll=1&since=<id>` HTTP endpoint
maps straight onto the exclusive-after cursor logic the connector already has.

### 3.3 The Keychain attribute becomes a trap

`Keychain.swift` writes `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and its
own doc comment already anticipates the problem: *"On the file-based login
keychain the attribute is advisory; it becomes enforced if the app ever adopts
the data-protection keychain."* iOS **is** the data-protection keychain.

Consequence: a background refresh that fires while the phone is locked cannot
read the token, and fails with a Keychain error that looks identical to a
revoked token. That is a textbook instance of this project's recurring bug
class, in a place nobody would think to look. Two changes:

- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on iOS (still never
  syncs off-device, still encrypted at rest — just readable after the first
  unlock since boot).
- The error path must name "the phone was locked" as its own reason, distinct
  from "the service rejected this token."

---

## 4. Three architectures, and which one I'd pick

### A. Pull-only. Zero infrastructure. *(recommended for v1)*
Foreground → `refreshNow()`; Slack's socket runs while foreground and is torn
down on background; `BGAppRefreshTask` as a best-effort top-up; snooze wakes as
scheduled local notifications; widget for the count.

Preserves decision §2.1.8 (zero infra) and every `authNote`'s promise that
tokens "never leave this Mac" — they'd just say "this device". No banners for
arrivals, which is *fine*, because you specifically said you don't want to rely
on push notifications. Costs: the freshness problem in §3.1, stated honestly in
the UI rather than papered over.

### B. The Mac is the relay. *(the growth path)*
The Mac app already runs 24/7, already holds every token, already polls
everything, and already has a bearer-token handshake in `LocalListener`. Give
it a companion mode and the phone becomes a view onto the Mac's queue:

- **CloudKit private database** as transport — Mac writes, phone reads,
  `CKSubscription` gives you real silent push with no server of your own. This
  is the only option that gets you genuine push while keeping tokens on the
  Mac. Two costs: it needs the iCloud entitlement + an App Group, which breaks
  the "no App ID registration, no provisioning profile, no entitlements at all"
  property the Distribution section of `CLAUDE.md` is rightly proud of (for the
  iOS side and a Mac update, not the current release); and SwiftData's CloudKit
  mirroring won't accept `@Attribute(.unique)` or non-defaulted properties —
  which `Item.uid` and `SourceConfig.id` both are. That means a **mirror
  schema**, not the same models. See §9.
- **Tailscale / local network** to the existing listener — no cloud at all,
  generalises the `LocalListener` handshake almost unchanged, and works on
  cellular only through the VPN. Free, honest, nerd-grade.

Either way this is where the `local` source comes back to life, and it's the
best argument for doing it: *"Claude Code is waiting for you"* pushed to your
phone is a genuinely good feature, and it's the one thing the phone can do that
the Mac can't.

### C. Hosted relay (Cloudflare Worker, §4.4's deferred item).
Real push, real freshness, real APNs. It also inverts the app's core promise:
the relay must hold your tokens to poll on your behalf, so all five
`authNote` strings that end "never leaves this Mac" become false. Slack Socket
Mode can't run on a Worker at all (needs a persistent socket — Durable Object
with hibernation, or an actual process). And if anyone else uses it you are now
the custodian of other people's `xoxp-` tokens. That's a product with an
on-call rotation, not an evening project.

**Recommendation: A now, B if the pull rhythm annoys you, C never** — or at
least not before A has taught you whether push is actually the missing piece.

---

## 5. What the UI becomes

The Mac interaction vocabulary translates cleanly, which is a good sign for the
design rather than a coincidence:

| Mac | Touch |
|---|---|
| `E` mark done | trailing swipe; full-swipe = done, with the existing `undoStack` behind a toast |
| `S` snooze | leading swipe; long-swipe opens the `SnoozeMenu` durations (which already port) |
| `⌘P` pin, `U` unread, copy | long-press context menu |
| `←`/`→` source cycling | scrollable filter chips — `FilterBar`'s model ports, the chrome doesn't |
| Row expands on selection | tap to expand. `ExpandingText` is *already* a touch idiom; it just needs `UIFont` for measuring |
| Sticky source headers | unchanged — plain SwiftUI |

**iPadOS is where the main window earns its keep**: `MainWindowView`'s table
becomes a three-column `NavigationSplitView` (sources │ queue │ detail). And
because `MainWindowCommands.swift` drives everything through
`@FocusedValue(\.triageActions)` rather than reimplementing triage, the ⌘-key
shortcuts survive on iPad with a Magic Keyboard nearly for free. That
architectural choice pays off on a platform it wasn't made for.

Genuinely new wins available only here: a **widget** (see §3.1), a **Control
Center control / Action Button** binding, and Siri/Shortcuts — which come almost
free, since `Intents/QueueIntents.swift` already exposes get/count/snooze/
mark-done against the same `Store`.

The one output that doesn't survive: **journaling to Obsidian.** The logic in
`JournalWriter` is pure and ports, but the destination doesn't — iOS is
sandboxed, an Obsidian iOS vault lives inside Obsidian's own container, and
even a user-picked folder needs a security-scoped bookmark. Either drop it on
iOS or write to a shared container the Mac drains.

---

## 6. Distribution inverts

This is the sharpest practical constraint, and it flips decision §2.1.7 on its
head.

- **There is no Developer-ID equivalent.** No notarize-and-put-a-zip-on-GitHub
  path exists on iOS. It's App Store, or TestFlight (builds expire at 90 days),
  or a personal install signed with your own account and re-signed when it
  lapses. "Personal-first, GitHub release later" has no iOS translation.
- **The App Sandbox is mandatory** — the thing §2.1.7 explicitly rejected on
  Mac because it fights the terminal/CLI features. On iOS those features are
  gone anyway, so the sandbox costs almost nothing. Unusually, this is good
  news.
- **App Store review is a real risk, not a formality.** An app whose primary
  function is aggregating third-party services, set up by pasting a Slack user
  token, will draw questions about credential handling and authorisation, and
  reviewers want a demo account — which "paste your own `xoxp-` token" cannot
  provide. Plan for a written explanation and a demo path (the `fake`
  connector is genuinely useful here), and accept that rejection is possible.
- The Mac target keeps its existing Developer ID + notarization pipeline
  untouched. Two platforms, two entirely separate release processes, one repo.

Practical read: if this is for you and a handful of friends, personal signing or
TestFlight is the realistic answer, and the yearly re-sign is the tax.

---

## 7. Repo shape

`project.yml` currently has three targets, all `platform: macOS`, all pointed at
`Sources/App`. The clean move is a source split rather than `#if os(...)`
sprinkling — there's too much UI for conditionals to stay readable:

```
Sources/Core/     models, Sync, Support, Journal logic, Intents,
                  Linear/GitHub/Slack/Ntfy/JSONPoller   → multi-platform
Sources/Mac/      UI/, Connectors/Local/, menu bar, AppState's Mac half
Sources/iOS/      new UI, iOS AppState half
Sources/CLI/      unchanged, Mac only
```

A side benefit worth having regardless of whether iOS ever ships: the test
target currently sets `TEST_HOST` to the app bundle, so tests need the whole
app to run. Pointed at `Core` instead, they'd run on both platforms without
one.

**And a warning about rule 1.** "`xcodebuild test` installs nothing" gets
*worse* here. The `strings -a` check against `/Applications/Inbox & Chill.app`
has no device equivalent — you can inspect a simulator build the same way, but
verifying what's actually running on a phone means a device install and a
different recipe. Whatever that recipe turns out to be needs writing down in
`CLAUDE.md` before the first "but the test passed" cycle, not after.

---

## 8. What I'd build, in order

1. **Split `Sources/Core` out, keep the Mac app green.** Pure refactor, no iOS
   yet, immediately useful (tests stop needing the app bundle).
2. **iPhone app, pull-to-refresh, GitHub + Linear + JSON feeds + ntfy.** Four
   connectors that are stateless pollers and port unchanged. This is the whole
   idea, working, on a phone, with no infrastructure.
3. **Snooze wakes as scheduled local notifications** (and backport to Mac).
4. **Widget.** The honest badge.
5. **Slack**, after the persistence pass in §3.2 — not before.
6. **Then decide about push**, with three months of actually using it to argue
   from.

Steps 1–4 are a small number of evenings, precisely because the connectors and
their tests already exist and are already shaped right.

## What I'd push back on

Two things.

**This doubles the surface area of a project whose operating manual is a list of
things that silently broke.** A second platform, a second signing pipeline, and
(under B or C) a sync boundary — added to a codebase whose stated recurring bug
class is silent failure. The connector work is done; the *failure-surfacing*
work would all be new, on a device with less room for a red dot and no Console
to check. Every error path in `Sync/` currently terminates at a status dot in a
menu bar panel that doesn't exist on a phone.

**And the "replaces iOS notifications" framing is the part to hold loosely** —
see §3.1. It's the framing that quietly demands a server. The framing that
doesn't is just as good and ships this month.

---

## 9. Claims here that are stated from knowledge, not verified

In the spirit of rule 3 — a config that has never met the real service is
unverified, however carefully written. Nothing below was tested against an SDK,
a device, or Apple:

- **SwiftData + CloudKit rejects `@Attribute(.unique)` and requires all
  attributes optional or defaulted.** I'm fairly confident, and it's the load-
  bearing constraint under option B. Check it against the current SDK before
  designing a mirror schema around it.
- `BGAppRefreshTask` cadence and budget — "handful of times a day, seconds of
  runtime" is the documented shape, not a measured number.
- TestFlight's 90-day build expiry.
- That the `KeyboardShortcuts` package is macOS-only (it is, but confirm the
  version pinned in `project.yml`).
- App Store review outcomes for a paste-a-token aggregator. This is a
  judgement call about reviewers, not a rule anyone can look up.
- Whether Slack, Linear and GitHub's iOS apps claim universal links for the
  URLs the connectors emit. If they do, deep-linking is *better* on iOS than on
  Mac (no `NSWorkspace.urlForApplication(toOpen:)` probe needed — though
  `canOpenURL` needs `LSApplicationQueriesSchemes` in the plist for the
  `slack://` fallback in `AppState.openable`).
