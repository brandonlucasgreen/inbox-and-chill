# Testing Inbox & Chill locally

## 1. Build and install

```sh
brew install xcodegen   # once
scripts/install-local.sh
```

That builds a Release configuration, verifies the signature, installs to
`/Applications`, and launches. Look for the tray icon in the menu bar (this
is an `LSUIElement` app — no Dock icon until you open the ⌘0 window). First
launch asks for notification permission.

Add `--debug` for a Debug build (which includes the fake connector, §2), or
`--no-launch` to install without starting it.

### Why install instead of running from DerivedData

macOS ties **Keychain ACLs, TCC privacy permissions, and firewall
decisions** to an app's *code signature* and *path*. Two things used to
break both:

- Builds were **ad-hoc signed** (`CODE_SIGN_IDENTITY: "-"`), which has no
  stable identity. Every rebuild looked like a different app, so macOS
  re-prompted for everything — most visibly the Keychain, which this app
  touches on every token read.
- DerivedData paths contain a random hash and change whenever DerivedData
  is cleaned.

Builds are now signed with **Developer ID Application** (team
`CV926C8KS8`, set in `project.yml`) and installed to a stable location, so
you grant each permission once and it sticks across rebuilds.

**Credentials saved by an older ad-hoc build.** A Keychain item's access
control list records which app may read it, and an item created by an
ad-hoc build names an identity that no longer exists — so the properly
signed app matches nothing and macOS puts up the "wants to use your
confidential information" panel. Two ways to clear it:

- **Keep the credential:** when the panel appears, type your login password
  and click **Always Allow** (plain *Allow* is one-time and the panel comes
  straight back). This rewrites the item's ACL in place. Prefer this for
  anything you can't easily re-obtain — a Linear personal API key, for
  instance, is only displayed once when you create it.
- **Start clean:** delete the source in Settings and re-add it. Deleting
  prefix-wipes its Keychain entries, and re-adding writes a fresh item
  owned by the current build.

Note that `Keychain.set` deletes before adding rather than using
`SecItemUpdate`, so simply *editing* a source and re-pasting its token also
rebuilds the ACL correctly.

### Gatekeeper and notarization

`spctl -a -vvv "/Applications/Inbox & Chill.app"` reports `rejected —
source=Unnotarized Developer ID`. **This is expected and doesn't affect
local use:** Gatekeeper only evaluates apps carrying a quarantine
attribute, which is set on downloads, not on locally built apps. The app
launches normally.

Notarization is the remaining step before *distributing* the app to anyone
else (PLAN §2.1.7). It needs an App Store Connect API key or an
app-specific password, so it's a manual step:

```sh
xcrun notarytool submit "Inbox & Chill.zip" --keychain-profile "<your-profile>" --wait
xcrun stapler staple "/Applications/Inbox & Chill.app"
```

### Building this yourself (not Brandon)

Change `DEVELOPMENT_TEAM` in `project.yml` to your own Team ID
(`security find-identity -v -p codesigning` lists yours), or build unsigned
with `xcodebuild CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO`.

## 2. Ride the fake connector (no accounts needed)

In Debug builds with no real sources configured, a **fake connector** feeds
the queue: a Slack-style mention, a PR review request, a Linear-style
assignment, plus a fresh fake DM every minute or so. Use it to exercise the
whole triage loop:

- **⌥⌘I** (or click the tray icon) — open the panel
- **↑/↓** select · **⏎** open · **E** done · **⌘Z** undo · **S** snooze
  (presets popover) · **D** show the whole message (**Esc** closes it again) · **⌘P** pin · **⌘C** copy ·
  type to filter · **⌘1…⌘9** source chips · **Esc** peels back one layer at a
  time
- Watch the fake "remote" behave: marking the mention done tells the fake
  connector, so it stays gone on the next poll (write-through, same code
  path real connectors use).
- Toggle badge modes in Settings → General and watch the tray icon.
- Footer: archive box icon → the 90-day archive with search + Restore;
  window icon (**⌘0**) → the full triage window with sortable columns and
  multi-select.

To silence the fake source, set `INCHILL_NO_FAKE=1` in the scheme's
environment (Xcode: Product → Scheme → Edit Scheme → Run → Arguments).

## 3. Test the local pipeline (terminal + Claude Code)

The app auto-creates the "Local coding agents" source and starts a
localhost listener. The CLI lives inside the app bundle:

```sh
alias inchill='~/Library/Developer/Xcode/DerivedData/InboxAndChill-*/Build/Products/Debug/"Inbox & Chill.app"/Contents/MacOS/inchill'
```

```sh
inchill notify --title "Hello from the terminal" --url "https://bgreen.lol"
```

The item appears in the panel instantly (banners default ON for this
source). Clear it:

```sh
inchill notify --id my-task --title "Long build running"
inchill done my-task
```

**Claude Code:** Settings → General → Claude Code → "Set Up Integration"
(backs up `~/.claude/settings.json` first, merge is additive). Then start
any Claude Code session: when it waits for permission or input, a
high-signal "Claude Code needs your input" item appears — and clears
itself the moment the session moves on, leaving a quiet "Claude finished
in <project>" breadcrumb. Simulate without a real session:

```sh
echo '{"session_id":"demo","cwd":"'$PWD'","message":"Needs permission"}' | inchill claude-hook notification
echo '{"session_id":"demo","cwd":"'$PWD'"}' | inchill claude-hook stop
```

## 4. Connect real sources (Settings → Sources → +)

Fastest first:

1. **Linear** (~2 min): linear.app → Settings → Security & Access → personal key. Items
   mirror your Linear inbox; mark-done archives there; snoozes sync.
2. **GitHub** (~3 min): classic PAT with `notifications` scope
   (github.com/settings/tokens — fine-grained tokens don't work), authorize
   SSO for the Buffer org if prompted.
3. **Slack**: create the app from `docs/slack-app-manifest.yml` (see
   `docs/setup-sources.md`), install to the workspace (may need admin
   approval), paste the xoxp + xapp tokens. Then: have someone @-mention
   you, watch it arrive live; react to any message with 📌 and watch it
   become a saved item; remove the reaction and watch it clear.

## 5. Run the test suite

```sh
xcodebuild -project InboxAndChill.xcodeproj -scheme InboxAndChill test
```

33 tests, 5 suites, all deterministic (no network).

## 6. Reset to factory

```sh
pkill -f "Inbox & Chill"
rm -rf ~/Library/Application\ Support/InboxAndChill
defaults delete lol.bgreen.inboxandchill 2>/dev/null
```

Keychain items live under service `lol.bgreen.inboxandchill` in Keychain
Access if you want to purge tokens too.
