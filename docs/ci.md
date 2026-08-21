# CI — what it is, what it checks, what it costs

CI ("continuous integration") is a robot that opens every pull request on a
clean Mac it has never seen before, builds the app from scratch, and runs the
tests. Nothing more mysterious than that. Its value is not that it does
anything you couldn't do by hand — it's that it does it on a machine with none
of your setup on it, every time, without anyone remembering to.

The whole thing lives in `.github/workflows/`. It runs automatically; you never
have to start it.

## What runs, and why each one is here

### 1. Shell scripts (Linux, under a minute)

`scripts/check-shell.sh` — three things:

- **Every script still parses.** A typo in `release.sh` shouldn't be discovered
  halfway through cutting a release.
- **shellcheck**, a standard linter for shell scripts.
- **The bash 3.2 empty-array trap.** macOS still ships bash 3.2 from 2007,
  where a shell script that expands an empty list crashes instead of doing
  nothing. This shipped broken in `appcast.sh` and would have failed *every
  real release* — the broken path was the default one, and the path that got
  tested was the one an environment variable turned on. The checker greps for
  the unsafe pattern. If an array genuinely can never be empty, a `# bash32-ok`
  comment above the line excuses it and says why.

### 2. Build and test (macOS, about 3 minutes)

Generates the Xcode project from `project.yml`, resolves the Swift packages,
builds the app and the `inchill` CLI, and runs the whole test suite.

This is the one that matters most, and the reason it's worth having is
narrower than "it runs the tests": **it builds on a machine with no local
state.** No DerivedData, no cached packages, no Xcode project lying around
from three branches ago. A build that only works on your Mac is a build that
will fail on someone else's — and this repo has other contributors now.

If tests fail, the results bundle is attached to the run so the failure can be
opened in Xcode rather than read out of a log.

### 3. Release-shaped bundle audit (macOS, same job, conditional)

Builds a second time in Release configuration and runs
`scripts/verify-bundle.sh`, which inspects the finished `.app` for the things
that **produce no build failure at all**:

| Checked | Why |
|---|---|
| `SUFeedURL` is in the Info.plist | `INFOPLIST_KEY_SUFeedURL` once built, signed and shipped a bundle with no feed URL in it, silently. Sparkle would have had nothing to read. |
| `SUPublicEDKey` is present | Without it the app can't verify an update it downloads. |
| Version numbers match `project.yml` | XcodeGen's defaults pin a generated plist to "1.0" / "1". That breaks the About pane, the release zip's filename, and Sparkle's "is this newer?" comparison — so no install would ever be offered an update. |
| `LSUIElement`, `LSMinimumSystemVersion`, `NSAppleEventsUsageDescription` | Each absence is invisible until a user hits it. |
| The `apple-events` entitlement is present | Without it macOS refuses every Apple event with no consent prompt at all, and Apple Mail plus the Claude Code tab-focus both look like "nothing happened". This is exactly how 0.3.0 shipped. |
| `get-task-allow` is **absent** | Xcode injects the debugger-attach entitlement unless told not to, and notarization rejects a build carrying it. |
| Hardened runtime is on | Same: a notarization rejection, discovered a long way from its cause. |
| Sparkle's nested helpers exist where `project.yml` expects them | The re-signing step in `project.yml` walks a hardcoded list of paths and *silently skips anything it can't find*. If Sparkle ever moves them, that step passes while signing nothing, and notarization is the first thing to object. |

This second build doesn't run on every pull request — it's a full rebuild, and
everything it catches lives in `project.yml`, `InboxAndChill.entitlements` or
`scripts/`. So it runs when one of those changes, and on every merge to `main`.

`scripts/verify-bundle.sh` also works on your own machine:

```bash
scripts/verify-bundle.sh                      # audit the Release build
scripts/verify-bundle.sh --configuration Debug
```

It overlaps a little with `scripts/notarize.sh`'s preflight. That's on purpose:
the preflight is stricter (it also demands a real Developer ID signature and a
secure timestamp, neither of which a CI machine can produce) and runs once per
release. This one runs on pull requests.

### 4. Secret scan (Linux, about a minute)

`gitleaks`, over **the entire git history**, not just the current files. This
app holds Slack, Linear, GitHub, ntfy and Sentry tokens, so a credential
committed by accident is the worst thing that could quietly land here — and no
test would ever notice one.

It also runs on a schedule every Monday, because gitleaks' detection rules
improve over time: a scan that was clean in March can find something in June
with no new commits.

The repo's `.gitleaks.toml` already records two deliberate exemptions and the
reasoning for each. If the scan fails, the fix order is in the workflow's own
failure message, and the first step is always **rotate the credential** —
force-pushing does not delete anything from GitHub.

## What CI deliberately does *not* do

**It never signs, notarizes, or releases anything.** No Developer ID
certificate, no notarization credentials, no Sparkle private key ever reaches a
runner. CI builds ad-hoc signed — enough to compile, run and inspect, not
enough to produce something a stranger's Mac would trust. Releases stay a thing
you run on your own machine with `scripts/release.sh`.

That's a security decision, not a gap. A CI system that can sign your app is a
CI system that can ship malware under your name if it's ever compromised. This
one can't.

**It doesn't run CodeQL** (GitHub's static security analyser). CodeQL on a
private repository requires GitHub Advanced Security, which is a paid add-on.
If the repo is ever made public — which is the plan, to make Sparkle updates
work at all — CodeQL for Swift becomes free and is worth turning on then.

**It doesn't check code style.** There's no SwiftLint or swift-format config in
this repo, and adding one would flag hundreds of existing lines on the first
run. Worth doing deliberately, some day; not worth bolting onto CI.

## What it costs

This repository is private, and GitHub bills private-repo Actions minutes
against a monthly allowance. **macOS minutes count as ten** — a four-minute
macOS job spends forty minutes of allowance.

Measured on the first green run (2026-08-21), a full pull request costs about
**42 minutes of allowance**: the macOS job took 3m18s (billed as 4 × 10), the
shell job 17s, the secret scan about a minute. On the Pro plan's 3,000 free
minutes that is roughly **70 pull requests a month** before it costs real
money. A run that skips the Release audit is nearer 2 minutes, and a warm
Swift-package cache saves another 25 seconds.

Those are real numbers, not estimates — but they will drift as the app grows,
and the macOS job is the only one worth watching.

Three things in the setup exist because of that:

- The cheap checks (shell, secrets) run on Linux, which bills at 1×.
- A new push to the same pull request cancels the run it superseded.
- The Release audit doesn't run on every pull request.

If it does start costing more than you like, the first lever is to change the
macOS job's trigger from `pull_request` to only `push: [main]` — you'd find out
after merging instead of before, which is worse but cheaper. Making the repo
public removes the cost entirely: Actions is free for public repositories.

## Making CI actually enforce anything

By default a red check is a red mark on the pull request and nothing more —
GitHub will still let it merge. To make it binding:

**Settings → Branches → Add branch ruleset**, targeting `main`:

- Require a pull request before merging
- Require status checks to pass, and select **Build and test**, **Shell
  scripts**, and **gitleaks**

Those names appear in the list once each workflow has run at least once, so
merge this first, then go set them.

## When something breaks that isn't your fault

Two things will eventually go red without anyone having changed the app:

- **The Xcode version moved.** This one has already happened once: the first
  CI run used `macos-15`, whose Xcode 16.4 / Swift 6.1.2 is old enough that
  `AppState.swift` doesn't compile under it — `UNNotificationSettings` isn't
  marked as safe to hand between concurrency domains in that SDK, and newer
  ones fix it. Nobody had touched that code; the compiler simply changed
  underneath it.

  So the job now lists every Xcode on the image, picks one deliberately, and
  prints it. Set `XCODE_VERSION` at the top of the `macos` job (e.g. `"26.4"`)
  to pin an exact one; leave it empty and it takes the newest installed. Pinning
  is the more reproducible choice once your Mac and CI are known to agree —
  empty drifts silently when GitHub updates the image.

  As of 2026-08-21 the `macos-26` image carries Xcode 26.0 through 26.6, and
  the job selected **Xcode 26.6 / Swift 6.3.3** on macOS 26.5.2. Every Xcode on
  that image is a 26.x, so the drift the empty setting allows is bounded.

  The general lesson: **a runner's Xcode is usually older than yours, not
  newer.** GitHub images lag Apple by months. If CI fails on code that builds
  fine locally, compare the two Swift versions before assuming the code is
  wrong.
- **The runner image was retired.** GitHub retires images a couple of years
  after release. The label is in `ci.yml`; bumping it is a one-line change, but
  do it as its own pull request so the build failures it causes are attributable.

## One recommendation this setup does not implement

`project.yml` declares its Swift dependencies as `from: 2.9.6` — meaning "2.9.6
or any later 2.x". So a build today and a build next month can pull different
Sparkle code, and nothing records which one shipped. For an app that handles
API keys, a compromised upstream release entering a build unnoticed is a real
(if unlikely) risk, and it's the standard way software supply chains get
attacked.

Changing `from:` to `exactVersion:` for both packages pins them, and updating
becomes a deliberate one-line commit you can see in a diff. The cost is that
you stop getting bug fixes automatically. CI prints the resolved versions on
every run in the meantime, so at least there's a record.

Worth a conversation; not something to change without one.
