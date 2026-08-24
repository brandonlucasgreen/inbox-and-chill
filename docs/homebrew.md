# Homebrew

Installing and updating the app with `brew`, and how the cask that makes that
work is maintained.

```bash
brew install --cask brandonlucasgreen/tap/inbox-and-chill
```

That one command adds the tap and installs the app; there is no separate
`brew tap` step. It also puts the `inchill` CLI on `PATH`, so the shell
integration in [docs/shell-integration.md](shell-integration.md) needs nothing
further.

---

## Why a personal tap and not `homebrew/cask`

`brew install --cask inbox-and-chill`, with no owner in front, means the cask
lives in `homebrew/cask`, and that repo gates new submissions on the project's
popularity. From brew's own audit code
(`Library/Homebrew/utils/shared_audits.rb`):

```ruby
GITHUB_NOTABILITY_THRESHOLDS = { forks: 30, watchers: 30, stars: 75 }
```

Those thresholds are **multiplied by three when you submit your own project**
— 90 forks, 90 watchers or 225 stars — and the repo must be at least 30 days
old. This one is nowhere near that, so the question is not "when do we submit"
but "does the tap route work", and it does. A tap is an ordinary public git
repo; brew resolves `<owner>/tap/<cask>` to `<owner>/homebrew-tap`.

Worth knowing for later: `docs.brew.sh/Acceptable-Casks` rejects time-limited
trials *"unless activatable without re-downloading"*. A trial that unlocks with
a licence key pasted into Settings satisfies that, so shipping the trial does
not close the official door.

## Both updaters work, and they cannot fight

The cask declares `auto_updates true`, which does **not** mean brew leaves the
app alone. In current Homebrew (checked against 6.0.18,
`Cask#auto_updates_bundle_outdated?`), an `auto_updates true` cask is compared
against the **installed bundle's `Info.plist`** — `CFBundleShortVersionString`
and `CFBundleVersion` — rather than against brew's own record of what it
installed. So:

- Sparkle updates the app in place; brew reads the new version out of the
  bundle and sees nothing to do.
- `brew upgrade` updates an app whose bundle is genuinely behind, by default,
  with no `--greedy`. (`--greedy-auto-updates` still exists but is deprecated,
  with `replacement: "the default behaviour"`.) The one opt-out is the user
  setting `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS`.

Whichever updater gets there first wins and the other no-ops. That makes brew
a genuine second delivery path rather than a competing one — useful, because a
broken Sparkle release can be repaired with `brew upgrade` instead of a hand-
sent DMG.

One rough edge: `brew upgrade` quits the app to replace it and does not
relaunch it. Open it again, or leave it to the login item.

## What brew does not clean up

`brew uninstall --cask --zap inbox-and-chill` trashes the app, the SwiftData
store, preferences and caches. Two things it cannot reach, both listed in the
cask's `caveats`:

- **Keychain items.** Every source token and the licence key live in the login
  keychain under `lol.bgreen.inboxandchill`. Homebrew has no business touching
  a keychain, so those stay until deleted by hand.
- **Agent hooks.** `~/.claude/settings.json` (and the Codex and Gemini
  equivalents) hold an absolute path to `inchill` *inside the app bundle*.
  Delete the app and the hook runs a binary that no longer exists — and it
  exits 0 by design, so nothing says why. Turn hooks off in Settings before
  uninstalling.

## Already have the app installed?

Homebrew refuses to write over an app it does not own, so an existing manual
install cannot simply be replaced:

```bash
brew install --cask --adopt brandonlucasgreen/tap/inbox-and-chill
```

`--adopt` takes over the copy already in `/Applications` instead of failing.
Untested here as of 2026-08-24.

---

## Maintaining the cask

The canonical copy lives in this repo at
`packaging/homebrew/inbox-and-chill.rb`. **Edit that one**, never the copy in
the tap — the tap's copy is overwritten on every release.

`scripts/homebrew-cask.sh` does the release-time work, and
`scripts/release.sh` calls it after the GitHub release exists:

1. reads `MARKETING_VERSION` from `project.yml`
2. checksums `dist/dmg/InboxAndChill-<version>.dmg`
3. rewrites the `version` and `sha256` lines
4. **downloads the published asset and compares checksums**
5. copies the file into the tap and pushes it

Step 4 is the one that earns its place. A cask whose `sha256` does not match
the bytes GitHub serves fails for *every* user at once, and Homebrew reports it
as a checksum mismatch — which reads like a corrupted download or a MITM, not
like a stale cask. So the checksum is never typed by a person and never
trusted without checking it against the published artifact.

The cask step is deliberately **not fatal** to a release. By the time it runs
the tag, the release and the appcast are already public; an unreachable tap
should not read as a failed release. It prints what to re-run instead.

### Setting up the tap (once)

```bash
gh repo create brandonlucasgreen/homebrew-tap --public --add-readme \
  --description "Homebrew tap for Inbox & Chill"
```

The name **must** start with `homebrew-`, or `brew` will not resolve
`brandonlucasgreen/tap/...` to it. It must be public: brew fetches with no
credentials, exactly like Sparkle. Then:

```bash
scripts/homebrew-cask.sh     # needs dist/dmg/InboxAndChill-<version>.dmg present
```

### Checking a change to the cask

`brew` will audit a cask in a scratch tap, which is the closest thing to what a
user's `brew install` does without installing anything:

```bash
brew tap-new <you>/scratchtap --no-git
cp packaging/homebrew/inbox-and-chill.rb "$(brew --repository <you>/scratchtap)/Casks/"
brew audit --cask --strict --online <you>/scratchtap/inbox-and-chill
brew style <you>/scratchtap
brew livecheck --cask <you>/scratchtap/inbox-and-chill
brew untap <you>/scratchtap
```

`livecheck` reads `appcast.xml` — the Sparkle feed doubles as the cask's
version source, so a release that updates the feed also tells brew a new
version exists. Two audit findings worth not rediscovering:

- Without `&:short_version` the Sparkle strategy returns `0.3.4,7`
  (short version plus `CFBundleVersion`) and audit rejects it: *"Download does
  not require additional version components."*
- `depends_on macos: ">= :sequoia"` is autocorrected to
  `depends_on macos: :sequoia` by the `Homebrew/OSDependsOn` cop. The Cask
  Cookbook still reads as though the bare symbol pins one exact release; the
  cop is what current brew enforces.
