# Testing Inbox & Chill locally

## 1. Build and launch

```sh
brew install xcodegen   # once
xcodegen generate
xcodebuild -project InboxAndChill.xcodeproj -scheme InboxAndChill -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/InboxAndChill-*/Build/Products/Debug/"Inbox & Chill.app"
```

Or open `InboxAndChill.xcodeproj` in Xcode and hit ⌘R. Look for the tray
icon in the menu bar. First launch asks for notification permission.

## 2. Ride the fake connector (no accounts needed)

In Debug builds with no real sources configured, a **fake connector** feeds
the queue: a Slack-style mention, a PR review request, a Linear-style
assignment, plus a fresh fake DM every minute or so. Use it to exercise the
whole triage loop:

- **⌥⌘I** (or click the tray icon) — open the panel
- **↑/↓** select · **⏎** open · **E** done · **⌘Z** undo · **S** snooze
  (presets popover) · **⌘P** pin · **⌘C** copy · type to filter ·
  **⌘1…⌘9** source chips · **Esc** peels back one layer at a time
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

The app auto-creates the "Terminal & Claude Code" source and starts a
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

1. **Linear** (~2 min): linear.app → Settings → API → personal key. Items
   mirror your Linear inbox; mark-done archives there; snoozes sync.
2. **GitHub** (~3 min): classic PAT with `notifications` scope
   (github.com/settings/tokens — fine-grained tokens don't work), authorize
   SSO for the Buffer org if prompted.
3. **Slack**: create the app from `docs/slack-app-manifest.yml` (see
   `docs/setup-sources.md`), install to the workspace (may need admin
   approval), paste the xoxp + xapp tokens. Then: have someone @-mention
   you, watch it arrive live; react to any message with 📌 and watch it
   become a saved item; remove the reaction and watch it clear.
4. **Campsite**: needs a Doorkeeper token from whoever runs Buffer's
   instance; base URL + org slug + token.

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
