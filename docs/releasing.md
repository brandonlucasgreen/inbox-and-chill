# Releasing

How to cut a release, and what to check afterwards. Written to be walked
through step by step — with Claude Code or alone — because the failures here
are the kind that look fine locally and only show up on someone else's Mac.

`scripts/release.sh` does most of it. This document is the part that isn't
scriptable: what to have ready, what "worked" looks like, and which symptom
means which cause.

---

## Where things stand (2026-08-26)

**0.4.0 is a feature release**, and the first `.x` bump since to-do support
landed: Apple Reminders (#33) and Todoist (#35) are new source kinds, and #34
added crash and error reporting in Settings › Diagnostics.

`v0.3.5` shipped `CURRENT_PROJECT_VERSION` **8**. 0.4.0 ships **9**, which
`release.sh` enforces.

**0.4.0 is the first release that archives a dSYM.** Nothing before it has
one, and none can be recovered — a dSYM is matched to a binary by UUID and a
rebuild produces a different one. So a crash report from 0.3.5 or earlier
resolves to function names (the shipped binary keeps its Swift symbols) but not
to line numbers. From here on, `notarize.sh` writes
`dist/dsym/InboxAndChill-<version>.dSYM.zip` and `release.sh` attaches it.

**The in-app update path has still never been observed working end to end.**
0.3.4 → 0.3.5 was the first pair that could have tested it and nobody has
confirmed a Check Now finding it. `UpdateController.checkInterval` is 86,400 —
once a day — so "no update came through" usually means the check has not run
yet, not that the release is broken.

**Still free.** `Licensing.isEnforced` is `false`, so a shipped build has no
trial countdown, no expiry, and writes no trial start date. That is deliberate
while the app is pre-release — flipping it is its own decision, not part of
cutting a release. Do not flip it here.

---

## What you need on the machine

None of this is scriptable — it needs a person, once.

- **Xcode**, and `xcodegen` (`brew install xcodegen`)
- **A Developer ID Application certificate** in the login keychain
- **A notarytool keychain profile** named `inbox-and-chill`. Check it with
  `xcrun notarytool history --keychain-profile inbox-and-chill --verbose`;
  "Found Keychain password item" means it is there. Create it with
  `notarytool store-credentials` — see the header of `scripts/notarize.sh`.
- **The Sparkle EdDSA private key** in the login keychain (`scripts/sparkle-keys.sh`
  created it). Without it `appcast.sh` cannot sign the feed, and an unsigned
  entry is one Sparkle refuses.
- **`gh`, authenticated** — `gh auth status`

**Do this awake, at the keyboard.** The notary credentials live in the iCloud
"Local Items" keychain, which locks when the Mac sleeps and does *not* unlock
on a dark wake. An unattended release is unreliable for that reason alone, and
the error it produces ("No Keychain password item found for profile") reads
like the credentials were deleted when they are sitting right there.

---

## The release

### 1. Bump the version — its own commit, its own PR

In `project.yml`:

- `MARKETING_VERSION` → the new version, e.g. `0.3.4`
- `CURRENT_PROJECT_VERSION` → **must increase**, so `7`

```bash
xcodegen generate
```

Then branch, commit, PR, merge — the repo takes no direct pushes to `main`.

`CURRENT_PROJECT_VERSION` is the one Sparkle actually compares. If it does not
increase, every existing install reads the feed, concludes it is already
current, and never updates — a release that silently reaches nobody.
`release.sh` refuses to tag in that case and names the previous value, so this
is guarded rather than remembered. Leave it alone in ordinary feature branches;
it is a merge magnet, and the bump belongs to the release.

### 2. Dry run

```bash
git checkout main && git pull
scripts/release.sh --dry-run
```

Prints the plan and stops before changing anything: repo and visibility,
version and build number, the tag and the commit it will point at, both
artifact paths. Read it. If the version or the commit is not what you expect,
stop here — everything after this is outward-facing.

Preconditions it enforces, each preventing a specific mess: `gh` installed and
authenticated, on `main`, clean tree, in sync with `origin/main`, tag not
already taken, GitHub release not already taken, and the build number rule
above.

### 3. Cut it

```bash
scripts/release.sh
```

It asks for confirmation before anything outward-facing, then, in order:

1. `scripts/notarize.sh` — **clean** Release build, preflight, submit to
   Apple, staple, and write `dist/InboxAndChill-<version>.zip`,
   `dist/dmg/InboxAndChill-<version>.dmg` and
   `dist/dsym/InboxAndChill-<version>.dSYM.zip`
2. An annotated git tag, pushed
3. `gh release create` with both artifacts attached
4. `scripts/appcast.sh` — regenerates `appcast.xml`
5. `scripts/homebrew-cask.sh` — points the Homebrew cask at the new release,
   verifies its checksum against the published asset, and pushes it to the tap
6. One commit on `main` carrying the new `appcast.xml` and cask

Three artifacts because they have different jobs: Sparkle downloads the **zip**
to update an existing install; a person downloads the **dmg** the first time —
and so does `brew`. The **dSYM** is for you, months later: it is what turns a
crash report someone pastes into an issue from a function name into a file and
a line. Each lives in its own directory because `generate_appcast` treats every
archive beside the zip as another release.

```bash
atos -o "InboxAndChill-<version>.dSYM/Contents/Resources/DWARF/Inbox & Chill" \
  -arch arm64 -l <load-address> <frame-address>
```

Step 5 is the only one that is **not fatal**. By the time it runs, the tag, the
release and the feed are already public, so an unreachable tap must not read as
a failed release; it prints the one command to catch up. See
[docs/homebrew.md](homebrew.md).

It always rebuilds and re-notarizes rather than attaching whatever is sitting
in `dist/`. That is the point — a tag whose artifact was built from different
code is worse than no tag.

Expect several minutes at the notarization step. That is Apple, not a hang.

---

## Verify what shipped

A green release script is not proof. Four checks, each catching something the
script cannot see.

### The feed is reachable and current

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/brandonlucasgreen/inbox-and-chill/main/appcast.xml
```

Expect `200`. raw.githubusercontent caches for about five minutes, so a release
you just cut is not offered instantly — wait before concluding anything.

### The download the feed names actually exists

```bash
curl -sSL -o /dev/null -w '%{http_code}\n' \
  https://github.com/brandonlucasgreen/inbox-and-chill/releases/download/v<version>/InboxAndChill-<version>.zip
```

Expect `200`. GitHub release URLs embed the tag, and `appcast.sh` inserts
`v<version>/` per enclosure after `generate_appcast` runs; this is the check
that the insertion worked. Safe because the signature covers the archive
bytes, not the URL.

### The appcast entry is signed

```bash
grep -c 'sparkle:edSignature' appcast.xml
```

`generate_appcast` signs an enclosure **only** when the app inside that archive
declares `SUPublicEDKey`. An entry without a signature is one Sparkle refuses
— nobody updates, and nothing says why. `appcast.sh` fails outright when the
newest entry is unsigned, so this is belt-and-braces.

### The cask points at bytes that exist

```bash
brew update && brew info --cask brandonlucasgreen/tap/inbox-and-chill
```

Expect the new version. `scripts/homebrew-cask.sh` already downloaded the
published asset and compared its checksum before pushing — a mismatch there
aborts rather than shipping a cask that fails for every user at once — so this
is confirming the tap got the push, not the checksum.

### Gatekeeper accepts it the way a stranger receives it

`spctl` skips unquarantined apps entirely, so testing the copy you just built
proves nothing. Test the artifact as it arrives:

```bash
ditto -x -k dist/InboxAndChill-<version>.zip /tmp/gk && \
  xattr -w com.apple.quarantine "0083;00000000;Safari;" "/tmp/gk/Inbox & Chill.app" && \
  spctl -a -vvv --type execute "/tmp/gk/Inbox & Chill.app"
```

Expect `accepted`, `source=Notarized Developer ID`.

And stapling is separate from being notarized — an unstapled build passes
while the machine can reach Apple and fails offline:

```bash
xcrun stapler validate "/tmp/gk/Inbox & Chill.app"
```

---

## When it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `No Keychain password item found for profile` | The Local Items keychain is locked — usually the Mac slept. Not deletion. | Touch the machine, re-run. `notarytool history` confirms the item exists. |
| `HTTP 400: Invalid previous_tag` from `gh release create` | The previous tag exists locally but was never pushed. GitHub resolves `--notes-start-tag` on the remote; `git describe` answers from your clone. | Fixed 2026-08-23 — `release.sh` now checks `git ls-remote` first and publishes un-anchored notes instead of failing. If you see it on an older copy: the tag is already pushed, so re-run `gh release create` without `--notes-start-tag`, then `scripts/appcast.sh`. |
| `release.sh` refuses: `CURRENT_PROJECT_VERSION is N, but vX already shipped N` | The build number did not increase. | Bump it. This is the guard working. |
| Preflight fails on a broken seal | An incremental Release build ran `ExtractAppIntentsMetadata` after codesign. | `notarize.sh` already does `clean build`; if you built by hand, don't. |
| Notarization rejects the build | `get-task-allow` injected, or no secure timestamp. | Both are set in `project.yml` under `settings.configs.Release`. `scripts/notarize.sh --preflight-only` catches them with no credentials needed. |
| Nested Sparkle helpers ad-hoc signed | Xcode's embed step re-signs only the framework bundle. | The "Re-sign Sparkle's nested helpers" phase in `project.yml` handles it; `notarize.sh`'s preflight checks each nested item. `codesign --verify --deep` does **not** catch this and never did. |
| App says "Couldn't read the update feed" | `appcast.xml` is missing or 404s. | Expected until the first Sparkle release ships. After that, check the feed URL. |
| App says "This build has no update feed" | The build has no `SUFeedURL` — i.e. it predates the Sparkle wiring, or was built from a clone that stripped it. | Nothing to fix in the feed; that install needs replacing by hand. |
| `the tap repo … does not exist` | The tap has not been created, or `gh` cannot see it. | `gh repo create brandonlucasgreen/homebrew-tap --public --add-readme`, then re-run `scripts/homebrew-cask.sh`. The release itself is fine. |
| `checksum mismatch` from `homebrew-cask.sh` | The DMG in `dist/` is not the one GitHub is serving. | Do not publish the cask. The release asset and the local build disagree, so re-cut the release. |
| `brew install` reports a checksum mismatch | A cask was published without the verification step — the sha256 does not match the asset. | Re-run `scripts/homebrew-cask.sh`, which checksums the published asset rather than trusting `dist/`. |

`scripts/notarize.sh --preflight-only` checks a build is submittable without
any credentials at all. It is the cheapest way to find out whether a release
would fail, and CI cannot do it for you — no runner has the Developer ID
certificate, by design.

---

## After the first Sparkle release

Once a build carrying Sparkle is out:

1. Install it by hand from the `.dmg` — this is the unavoidable hop.
2. Confirm **Settings → General → Updates** shows no configuration problem.
   `UpdateController.configurationProblem` reports a missing feed URL or
   missing public key there rather than failing silently later.
3. On the release *after* that, the real end-to-end test becomes available:
   from the older install, trigger a check and confirm it offers, downloads,
   verifies and installs the newer one. Until two Sparkle-capable releases
   exist, there is nothing to update *from*, and that path stays untested.

Point 3 is worth writing down as a known gap rather than assumed working. The
update path is the one thing in this project that cannot be exercised until it
has already shipped twice.
