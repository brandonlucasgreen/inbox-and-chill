# Mac App Store — one tree, two targets (plan, 2026-09-08)

Status: **phases 1–2 built (this and the following PR); phases 3–5 to do on a
Mac.** Brandon's call, 2026-09-08, after the audit below: *"far less
kneecapped of an app than I thought … I want to still reserve the right to
release a 'richer' app outside the MAS."*

This supersedes the *conclusions* of PLAN §2.1.8 and §2.1.10 without
contradicting their evidence: the sandbox findings there still hold, and this
plan is built on them. Read those two sections first if you have not.

## 1. The audit, condensed

Read on 2026-09-08 from the source tree; nothing was built sandboxed for
this pass. Guideline numbers are from the App Store Review Guidelines as
remembered — check them against the current text before quoting.

### Hard blockers (a rejection or a failed upload)

| # | What | Why | Fix |
|---|---|---|---|
| 1 | Licensing (`Licensing`, `LicenseController`, `LicenseSection`, `LicenseNotice`, `TrialNudge`) | 2.4.5(vi) bans license keys and own copy protection; 3.1.1 bans the Lemon Squeezy "Buy" links. `isEnforced = false` does not help — the code and checkout URL are in the binary. | Compile out of the store build. Store build is paid-upfront or IAP. |
| 2 | Sparkle | 2.4.5(vii): updates come from the store. Its `Autoupdate`, `Updater.app` and two XPC services are separate executables that would each need the sandbox entitlement. | Drop the package dependency from the store target; `UpdateController` becomes a stub. |
| 3 | App Sandbox off | 2.4.5(i). Every executable in the bundle needs it, including `inchill`. | Sandbox entitlement on the store target; no `inchill`. |
| 4 | `inchill` + agent hooks (Claude Code, Codex, Gemini) | Writes `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json` — code in shared locations, 2.4.5(ii). Listener needs `network.server`; `local-api.json` moves into the container so the CLI cannot find it (§2.1.8). | Cut from the store build: `Connectors/Local`, the CLI, the terminal session jump. |
| 5 | Apple Mail | Sandbox scripting access to Mail is compose-only (§2.1.10). `C` now also *moves* messages, so the Apple-events footprint grew. | Cut from the store build: `Connectors/Mail`. |
| 6 | Journal | User-typed path with `{{YYYY}}` tokens; iCloud Obsidian vaults need Full Disk Access, which a sandboxed app cannot be granted. | Cut from the store build: `Journal/`. |
| 7 | Private API in `PanelToggler` | KVC into `NSStatusBarWindow.statusItem`, 2.5.1. Survives every feature cut. | **Done, phase 1:** walks the view hierarchy for the public `NSStatusBarButton`. |
| 8 | Info.plist / manifest | No `LSApplicationCategoryType` (upload rejected), no `ITSAppUsesNonExemptEncryption`, no `PrivacyInfo.xcprivacy` (`UserDefaults` and file modification dates are "required reason" APIs). | Add all three to **both** builds. |
| 9 | Signing config | Needs App ID, Apple Distribution cert, provisioning profile. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` and `--timestamp` are Developer ID concerns set project-wide; the store target needs the injected base entitlements. | Move those two settings onto the direct target. |

### Degrades under the sandbox (verify on a Mac)

- **Diagnostics loses two of six readers.** `CrashHarvester` reads
  `~/Library/Logs/DiagnosticReports`, which redirects into the container and
  finds nothing. `UnifiedLogReader`'s `OSLogStore.local()` may be refused
  (its own comment says the no-entitlement result was measured *unsandboxed*).
  `ProblemLog`, `RunMarker`, `ExceptionTrap`, Copy Report, email, GitHub and
  Export all live beside the store and keep working. See §4 for the
  replacement.
- **Reminders** needs `com.apple.security.personal-information.calendars`
  (PLAN §6.6 already says so).
- **Keychain** becomes container-scoped. No migration for a new product.
- Launch at login (`SMAppService`), every REST/WebSocket connector,
  KeyboardShortcuts' Carbon hotkey, App Intents, notifications, pasteboard,
  SwiftData: sandbox-legal with `network.client` only. `FakeConnector` is
  `#if DEBUG`.

### Review risk that is not code

- **Guideline 2.1, completeness.** Every surviving notification source is
  bring-your-own-credential. Review notes need a working Slack app plus
  manifest, a classic GitHub PAT, Linear, Sentry, or the app is an empty
  window. Reminders is a zero-setup source, but a to-do list, not the
  notifications the app is sold on.
- Privacy policy URL required in App Store Connect; none in the repo.
- The store listing cannot mention or link to the richer direct build
  (3.1.1, 2.3).

## 2. Mechanism: not a branch

A branch holding the cut features diverges from `main` on the first shared
change and every later feature needs porting twice. Instead: **one source
tree, two XcodeGen targets, one compile flag.** The rich build stays the
default scheme; nothing about today's workflow changes. The store build is
`main` with a shorter `sources:` list. Nothing is deleted, so the richer app
stays a `scripts/release.sh` away.

- **Second target** in `project.yml`, `InboxAndChill-AppStore`. Same
  `Sources/App` path with `excludes:` for `Connectors/Local`,
  `Connectors/Mail`, `Journal`, `Licensing`. No `inchill` dependency, no
  Sparkle package. `SWIFT_ACTIVE_COMPILATION_CONDITIONS: APP_STORE`.
- **Gate direction is `#if !APP_STORE`** around the rich code, never
  `#if APP_STORE` around store code. The unflagged read of any file is the
  full app, which is the one you develop against.
- **Excluded folders carry their own stubs.** `Journal/AppState+Journal.swift`
  and `Licensing/AppState+License.swift` hold the real extension methods and,
  in phase 3, an `#else` block of no-op methods with the same signatures.
  `AppState`'s call sites then compile unchanged in both builds; only its
  two *stored* properties (`license`, `journalError`) need a flag, because
  stored properties cannot live in extensions.
- **Own entitlements and Info.plist per target.** Direct keeps apple-events.
  Store: app-sandbox, network.client, personal-information.calendars,
  files.user-selected.read-write (diagnostics export). Store plist drops the
  Sparkle keys and the Apple-events usage string.
- **Same bundle ID for both.** Keychain, container, TCC grants and Shortcuts
  key off it, and a person installs one or the other. Two IDs only if you
  want both running on one Mac at once.
- **`verify-bundle.sh --app-store`**: sandbox entitlement present,
  apple-events absent, no `Sparkle.framework`, no `inchill`, category and
  encryption keys present, no `lemonsqueezy.com` or `SUFeedURL` string in
  the binary. Entitlements and framework presence are the hard checks;
  `strings` absence is weak evidence except for a URL literal.
- **CI builds both targets on every PR.** One extra `xcodebuild build` in the
  macOS job. Tests keep running against the direct target since they
  exercise cut features.

## 3. Seams, measured 2026-09-08

About thirty code lines in shared files touched the cut modules. Phase 2
removes roughly half by moving code rather than flagging it. What remains for
phase 3, as `#if !APP_STORE`:

- **Local agents (~10):** `ConnectorFactory` case, `ConnectorCatalog` entry,
  three `kind == "local"` checks and the `AgentHooks.all` loop in `AppState`,
  the Claude session jump in `AppState.open`, `SourceEditorSheet`
  (`AgentHooksSection`), `SourcesPane` (`AgentHooksNotice`), the Automation
  link in `PanelView`, the `FirstRun` kind filter.
- **Mail (~5):** `ConnectorFactory` case, `ConnectorCatalog` entry,
  `mailAutomation` state and `resolveMailAutomation` in `AppState`,
  `SourceEditorSheet` (`MailAccessSection`).
- **Licensing and journal:** one seam each in `PanelView`, `MainWindowView`
  and `SettingsView`, plus the two `AppState` stored properties and the
  `license.state.allowsSync` guard in `bootstrapConnectors`.
- `AppLog.Category` keeps every case in both builds. A log category for a
  feature that is not compiled in is harmless.

## 4. Crash reporting without the OS report: MetricKit

Decided 2026-09-08. `CrashHarvester` gains a second source and everything
downstream is unchanged.

- **`MXMetricManager` / `MXCrashDiagnostic`** delivers crash payloads to the
  app itself on its next launch (macOS 12+), sandbox-safe, no entitlement, no
  third-party code, no network. Exception type, signal, and a call-stack tree
  per thread. Fits both builds, so build it once and keep the `.ips` reader
  as a second source for the direct build.
- **Stacks arrive unsymbolicated** — addresses plus binary UUID and offset.
  `CrashReportFile`'s signature logic needs a symbolication step against the
  dSYM that `notarize.sh` already archives (and that the store archive must
  upload). Until then the signature is "crash in `<binary>` at `<offset>`".
- **Delivery is "next launch"**, which for a menu bar app is the relaunch
  after the crash. Launch at login helps.
- **Being told about it:** when `RunMarker` sees a crashed previous run, offer
  "Inbox & Chill quit unexpectedly last time. Send the report?" and open the
  prefilled email `DiagnosticsReport` already composes, MetricKit stack
  attached. No infrastructure, the user chose to send it. Do **not** post to
  an ntfy topic baked into the binary — writable by anyone, so a spam vector.
  Apple's own pipeline (Xcode Organizer › Crashes, for users who share
  analytics) is free and passive: upload the dSYM with the archive and check
  it, but nothing there notifies you.
- **Breadcrumbs:** if `OSLogStore.local()` is refused under the sandbox, add a
  bounded file sink in `AppLog`. Only once the refusal is confirmed on a Mac.
- **Rejected:** hosted crash SDKs (Sentry, KSCrash, PLCrashReporter). Legit
  again under the sandbox since the OS report is unreadable, but a hosted one
  is telemetry: a "Crash Data" privacy-label row, a consent toggle, another
  binary to sign, a service to run. MetricKit gives the same stack without
  any of that.

Not verified: that MetricKit delivers for a sandboxed `LSUIElement` app.
MetricKit does not deliver while running under the debugger; use Xcode's
Debug › Simulate MetricKit Payload to exercise the parser, and a real
relaunch to see delivery.

## 5. Phases

1. **`PanelToggler` on public API** — done, this PR. Standalone; benefits the
   direct build now. **Verify on a real install (rule 1):** press ⌥⌘I, the
   panel toggles; `/usr/bin/log show --last 5m --predicate 'subsystem ==
   "lol.bgreen.inboxandchill"'` shows no `hotkey: no NSStatusBarButton` line.
2. **Two seam-reducing refactors** — done, the following PR, no flag defined
   yet, no behaviour change:
   - `UpdateController` is stub-ready: `import Sparkle` and the Sparkle code
     sit under `#if !APP_STORE`, with an `#else` stub reporting "Updates come
     from the App Store" and `canCheck = false`. Six seams (app root, main
     window commands, Diagnostics pane and report, About, Settings) go away.
     The `#else` branch is **uncompiled until phase 3** — the first store
     build will tell.
   - Journal prefs and recording move from `AppState` into
     `Journal/AppState+Journal.swift`; `JournalSettingsSection` into
     `Journal/`. Licensing files move into `Licensing/`, with the trial
     nudge and callback wiring in `Licensing/AppState+License.swift`.
3. **The store target.** `project.yml` second target, store entitlements and
   Info.plist, `PrivacyInfo.xcprivacy` for both, the `#if !APP_STORE` seams
   from §3 plus the `#else` stubs, Diagnostics degrading *out loud* (rule 5:
   the pane says why crash reports are unavailable rather than showing
   nothing), MetricKit source for `CrashHarvester`, the crash-relaunch send
   prompt, `verify-bundle.sh --app-store`, CI building both. Then build the
   store target locally and **run it sandboxed**: Reminders under the
   calendars entitlement, Slack Socket Mode connects, Keychain writes land in
   the container, Export via the save panel works, `OSLogStore` behaviour,
   MetricKit delivery.
4. **Apple paperwork (Brandon, on the Mac):** App ID, Apple Distribution
   certificate, provisioning profile, App Store Connect record, privacy
   policy URL, screenshots, review notes carrying demo credentials for Slack,
   GitHub and Linear. Archive through Xcode Organizer the first time, dSYM
   included. TestFlight for Mac before submission.
5. **Record.** Amend CLAUDE.md's Distribution section (which still says MAS
   was declined) and this doc's status line.

Two known costs, not problems. `CURRENT_PROJECT_VERSION` is shared, so a store
resubmission after a rejection bumps it and the direct build skips a number.
And the store listing describes the store app only.

## 6. Checklist for picking this up on a Mac

```bash
xcodegen generate
xcodebuild -project InboxAndChill.xcodeproj -scheme InboxAndChill -configuration Debug test
scripts/install-local.sh          # then press ⌥⌘I — phase 1's real test
/usr/bin/log show --last 5m --predicate 'subsystem == "lol.bgreen.inboxandchill"' --style compact | grep -i hotkey
```

Then phase 3, in this order: `project.yml` target → entitlements + plist →
`#if` seams + stubs → build the store scheme → run it sandboxed → MetricKit →
`verify-bundle.sh --app-store` → CI.
