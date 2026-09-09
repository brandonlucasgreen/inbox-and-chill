# Mac App Store — one tree, two targets (plan, 2026-09-08)

Status: **phases 1–3 built; phase 3 run sandboxed on a Mac and measured (§7);
phase 4 is Brandon's paperwork, phase 5 partly done.** Brandon's call,
2026-09-08, after the audit below: *"far less kneecapped of an app than I
thought … I want to still reserve the right to release a 'richer' app outside
the MAS."*

Build and run the store target with `scripts/build-app-store.sh --launch`.

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
- **The excluded folders' extension files carry the stubs, and are compiled
  into both targets.** `Journal/AppState+Journal.swift` and
  `Licensing/AppState+License.swift` hold the real extension methods under
  `#if !APP_STORE` and an `#else` block of no-op methods with the same
  signatures. The store target excludes each folder whole and then lists
  those two files as extra sources — an `#else` in a file the target does not
  compile would be no stub at all, which is what the first draft of this
  paragraph got wrong. `AppState`'s call sites then compile unchanged in both
  builds; only its two *stored* properties (`license`, `journalError`) need a
  flag, because stored properties cannot live in extensions. `JournalAction`
  lives above the `#if` in the journal file, because every triage verb names
  one when it calls `journal(...)`.
- **A settings view that belongs to a cut feature lives in the feature's
  folder**, not in `UI/Settings`: `Connectors/Mail/MailAccessView.swift`,
  `Connectors/Local/AgentHooksView.swift`. Same rule as phase 2's
  `Journal/JournalSettingsSection.swift`.
- **Both targets produce `Inbox & Chill.app`**, so built into one DerivedData
  they overwrite each other. `scripts/build-app-store.sh` builds into
  `build/AppStore` and copies to `dist/app-store/` — never `/Applications`,
  which would replace the direct build; `verify-bundle.sh --app-store` looks
  in the same derived data when not given `--app`.
- **`PrivacyInfo.xcprivacy` is at `Sources/App/Resources/`**, picked up by
  both targets as a resource; `verify-bundle.sh` checks it landed in
  `Contents/Resources/` in both flavours, because a resource that fails to
  copy produces no build error and the rejection arrives by e-mail.
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
3. **The store target** — done 2026-09-08. `project.yml` second target,
   store entitlements and Info.plist, `PrivacyInfo.xcprivacy` for both, the
   `#if !APP_STORE` seams from §3 plus the `#else` stubs, Diagnostics
   degrading *out loud* (the pane carries a secondary note saying the OS
   report is out of reach and MetricKit is the source), `MetricKitCrashes`
   feeding `DiagnosticsRecorder` beside the `.ips` reader, the
   crash-relaunch send prompt (`CrashPrompt`), `verify-bundle.sh
   --app-store`, `scripts/build-app-store.sh`, CI building and auditing the
   store target on every PR. Built and run sandboxed on this Mac; what was
   measured and what was not is in §7. **Still to exercise by hand** (needs
   a token or a click): Reminders under the calendars entitlement, Slack
   Socket Mode, a Keychain write from the sandboxed source editor, Export via
   the save panel, and the alert itself being visible.
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
`verify-bundle.sh --app-store` → CI. (Done; see §7.)

## 7. Phase 3 as built and measured (2026-09-08, macOS 26.6.2, Xcode 26.6)

Everything below was read from the sandboxed build's own log or its
container, running from `dist/app-store/`, signed Developer ID, with the
direct build running beside it.

- **It runs sandboxed, from nothing.** The first launch created
  `~/Library/Containers/lol.bgreen.inboxandchill/Data/Library/Application
  Support/InboxAndChill/store.sqlite`, logged `first run check:
  launchedBefore=false sources=0 … welcome=true` and `welcome window
  presented`, with **no sandbox denials** in the unified log. The relaunch
  logged `launchedBefore=true … welcome=false`.
- **TCC grants follow the bundle id.** Banner permission resolved `granted`
  on the store build's first launch, because the direct build had been
  granted it. Expect the same for Reminders — and expect the two builds'
  global hotkeys to clash while both run.
- **`OSLogStore.local()` is refused under the sandbox**: `Connection to logd
  failed`. `OSLogStore(scope: .currentProcessIdentifier)` works, so
  breadcrumbs in the store build cover the current run only and the export
  says so. §4's "add a bounded file sink once confirmed" is now a live
  question rather than a hypothetical; not done in this pass, because
  MetricKit turned out to carry the crash itself.
- **MetricKit delivers to a sandboxed `LSUIElement` app, immediately.** After
  `kill -SEGV` and a relaunch, `didReceive` fired **24 ms after launch**
  with one `MXCrashDiagnostic`; the report was on disk and in the pane's
  model before the first `refresh` finished, so no "quit unexpectedly with no
  report" line was written for a run MetricKit could explain.
- **The MetricKit frame offsets are the `.ips` offsets.** The crash's
  `.ips` (readable from a normal shell, not from the app) lists the same
  faulting-thread frames for our image; MetricKit's topmost own frame was
  `+ 0x8f450`, matching the `.ips` frame for `main`. So `atos -o <dSYM>`
  against these offsets will resolve — the release dSYM `notarize.sh`
  archives is the one to keep.
- **MetricKit's date is not the crash time.** The payload's `timeStampEnd`
  was `01:00:00Z`, forty-eight seconds *before* the kill at `01:00:48Z` —
  the window boundary, not the event. Ordering and "since dismissed" work;
  correlating against a log by time does not.
- **An external kill reads as a crash in `main`.** MetricKit has no
  `terminatedByProcess`, so the fallback signature names the outermost own
  frame; the `.ips` reader would say "sent by zsh" for the same event. A
  MetricKit-only crash titled `… in Inbox & Chill + <offset of main>` is
  therefore worth a second look before treating it as a bug in `main`.
- **A locally signed store build carries `get-task-allow`; an archive does
  not.** `xcodebuild archive` of the store scheme produced an app with
  exactly the four sandbox entitlements. `verify-bundle.sh --app-store`
  notes the key rather than failing on it.
- **`strings` on a Debug build's executable proves nothing.** Xcode 26 puts
  the code in `Contents/MacOS/Inbox & Chill.debug.dylib`; the executable is
  a 60 KB stub. The cut-feature literals were confirmed present in the
  direct build's dylib and absent from the store binary only after the
  control was pointed at the dylib. Recorded under rule 1 in CLAUDE.md.

Not measured, and needing a person at the keyboard: whether the crash
prompt's alert actually appears in front (no screen access from this
session; the log shows it was reached and not yet answered), Reminders under
the calendars entitlement, Slack Socket Mode, a Keychain write from the
sandboxed source editor, Export through the save panel.
