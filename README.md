# Inbox & Chill

**MIT licensed** — free to use, build, fork, and ship. See [LICENSE](LICENSE).

A native macOS menu bar app that pulls the things that actually need you out of Linear, GitHub, GitLab, Slack, Trello, Sentry, Apple Mail, Apple Reminders, Todoist, Asana, ntfy, any JSON feed, and your local coding agents (Claude Code, Codex, Gemini) into one queue — and then helps you empty it.

Inbox & Chill is a **triage queue, not a status mirror**. It doesn't try to be a client for any of these services — no composing Slack messages, no editing Linear issues. Items flow in, you act on them (open, done, snooze, pin, archive), and the queue goes to zero. The moment an item needs real work, it deep-links you into the app that owns it. The menu bar is the primary surface: click the icon (or hit a global hotkey) and a panel drops down with everything waiting for you, grouped by source.

## Features

**Sources**

Every source is added in Settings › Sources; nothing is pre-configured. Two need no account or token at all.

- Linear — full inbox mirror (mentions, assignments, comments), with real remote snooze
- GitHub — notifications inbox (review requests, mentions, assignments), folded by repository
- GitLab — your To-Do list (assigned, mentioned, approvals, broken pipelines), marked done in GitLab when you clear it
- Slack — mentions, DMs and keyword watches via Socket Mode, plus an emoji-reaction "save for later"
- Trello — your notification feed (mentions, cards you're added to, due dates), marked read in Trello when you clear it
- Sentry — the For Review tab, with resolving opt-in because it's team-visible
- Apple Mail — flagged or unread messages from every account Mail has, Gmail included; no token, one permission prompt
- Apple Reminders — what's due today or overdue, plus any lists you pick; no token
- Todoist and Asana — your tasks, with `C` completing them in the app that owns them and `E` only dismissing here
- ntfy — push notifications over a topic's WebSocket
- Custom JSON feeds — any URL that returns a JSON array, or an object holding one (`root=data`), with a one-line field mapping
- Local coding agents — the `inchill` CLI and hooks for Claude Code, Codex and Gemini, so a session that's waiting on you is one row in the queue

**Grouping**

Rows from one source fold by what they share — a Slack channel, a GitHub repository, a Linear issue, a mail sender — and a Topic collects rows from several sources under one name you choose. Both count as one on the badge.

**Two surfaces**
The menu bar panel is the default: click the icon (or hit a global hotkey) and it drops down over everything waiting for you, grouped by source. `⌘0` (or the window icon in the footer) opens the same queue as a regular window instead, with every triage action mirrored as a real menu item under **Queue** — useful for keeping it around on a second display.

**The selected row opens**
Every row is one line until you move onto it, and then it opens to a paragraph — two lines of title, four of message — and closes again as you arrow past. One line is enough to tell items apart and rarely enough to act on one, so the row you are actually looking at is the one that shows its text.

**Automation**
Siri Shortcuts / App Intents expose the queue outside the app: get items, get a count, snooze, or mark done from Shortcuts.app, Spotlight, or a voice command.

**Updates**
The app checks for new versions once a day and asks before installing anything, via [Sparkle](https://sparkle-project.org). You can turn the check off, or trigger one, in Settings → General → Updates. Builds you make yourself have no update-signing key, so they say so in that pane rather than failing quietly later.

**Triage verbs**
- Open — deep-links into the owning app or URL
- Done (`E`) — clears the item, with write-through where the service supports mark-read
- Undo (`⌘Z`) — brings back the last thing you marked done
- Snooze (`S`) — hides an item until later; real remote snooze on Linear, local elsewhere
- Pin (`⌘P`) — exempts an item from every auto-clear, done, and purge, until you unpin it
- Archive — done items live in a searchable 90-day archive, then purge automatically

**Badge modes**
The menu bar icon can show a total count, a high-signal-only count (the default), a plain dot, or nothing at all. Each source has its own "counts toward badge" toggle. Zero unread means a clean icon.

**Keyboard-first**

| Key | Action |
|---|---|
| `↑` / `↓` | Move selection |
| `⏎` | Open selected item |
| `⌘⏎` | Open selected item and mark done |
| `E` | Done |
| `S` | Snooze |
| `U` | Toggle read / unread |
| `D` | Show the selected item's whole message, or close it again |
| `⌘P` | Pin / unpin |
| `⌘Z` | Undo last done |
| `⌘C` | Copy (title + URL) |
| `←` / `→` | Cycle the source filter chips |
| `⌘1`…`⌘9` | Jump to a source filter chip |
| type | Type-to-filter the visible list |
| `⌘F` | Start typing a filter |
| `Esc` | Clear filter, close snooze picker, or close the panel |
| `⌘R` | Refresh all sources |
| `⇧⌘A` | Toggle the archive |
| `⌘0` | Open the queue in a window |
| `⌘,` | Settings |
| `⌘Q` | Quit |

## Requirements

- macOS 15 (Sequoia) or later

## Install

```sh
brew install --cask brandonlucasgreen/tap/inbox-and-chill
```

One command — it adds the tap and installs the app, and puts the `inchill` CLI on your `PATH`. `brew upgrade` keeps it current, and so does the app's own updater; they check the same feed and whichever gets there first wins. Already installed by hand? Add `--adopt` so brew takes over that copy instead of refusing to overwrite it.

Or download the `.dmg` from [the latest release](https://github.com/brandonlucasgreen/inbox-and-chill/releases/latest) and drag it to Applications. Both artifacts are notarized and stapled, so they open on a Mac that has never seen the app.

More on the tap, and what `brew uninstall` cannot clean up, in [docs/homebrew.md](docs/homebrew.md).

## Building

Inbox & Chill uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate its Xcode project from `project.yml`, so the `.xcodeproj` itself isn't committed.

```sh
brew install xcodegen
xcodegen generate
open InboxAndChill.xcodeproj
```

Or build from the command line:

```sh
xcodebuild -scheme InboxAndChill -configuration Debug build
```

To actually *use* the app day to day, install it rather than running it out of DerivedData:

```sh
scripts/install-local.sh
```

This builds signed, installs to `/Applications`, and launches. A stable path plus a real (non-ad-hoc) signature is what lets macOS remember Keychain, notification, and firewall permissions between builds instead of re-prompting every time — see [docs/testing-locally.md](docs/testing-locally.md).

**Signing:** builds use a Developer ID Application identity, configured via `DEVELOPMENT_TEAM` in `project.yml`. Building from your own clone means changing that to your Team ID, or passing `CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO` for an unsigned build.

**If you build unsigned, macOS will ask permission for every credential, on every rebuild.** This is not a bug in the app and there is nothing it can do about it. Secrets live in the login keychain, and a keychain item's access control records the *code identity* of whichever build created it. A signed build gets an identity-based requirement — bundle ID plus team — which every later build satisfies, so permission is granted once and never asked again. An ad-hoc build has no certificate to form that requirement from, so macOS pins the item to the binary's hash instead, and the next build is a different binary. Check what a given app records with:

```bash
codesign -d -r- "/Applications/Inbox & Chill.app"
```

Three ways out, in order of how much you'll like them: sign with your own Developer ID (`DEVELOPMENT_TEAM=<your team>`) and the problem never appears; click **Always Allow** rather than *Allow*, which grants the current binary standing access until you rebuild; or accept a prompt per credential per rebuild. Items created by an unsigned build stay poisoned after you switch to signing — re-enter the credential in Settings, which rewrites the item under the new identity (writes are delete-then-add for exactly this reason).

The build also compiles and embeds the `inchill` CLI inside the app bundle (`Contents/MacOS/inchill`), signed with the same identity — see [docs/shell-integration.md](docs/shell-integration.md).

**In-app updates, if you want them in your own build.** Sparkle verifies every
download against a public key baked into the app, and this repo deliberately
ships no key — so a fresh clone builds an app that says "no update-signing key"
in Settings rather than one that discovers the problem mid-install. To wire up
your own:

```sh
scripts/sparkle-keys.sh        # creates the keypair, prints the line to paste
xcodegen generate
```

You will also need somewhere to serve an `appcast.xml` your build can reach, and
`SUFeedURL` in `project.yml` pointed at it. None of this is needed just to use
the app.

## Contributing

Work lands via pull request. Every one gets built and tested from scratch on a
clean Mac by GitHub Actions, alongside a shell-script lint and a full-history
secret scan — see [docs/ci.md](docs/ci.md) for what each check is for, what it
deliberately doesn't do, and what it costs.

CI holds no signing credentials of any kind. Real signing, notarization and
releases happen on a person's Mac, via `scripts/release.sh`.

## Status

Built for one person's daily use first, and used that way every day. Three sources — GitLab, Trello and Asana — were written against their published APIs without a live account to test them on, and say so in their setup docs; if one misbehaves, [help@bgreen.lol](mailto:help@bgreen.lol) or an issue here is the fix.

The code is MIT licensed and the repository is public as of 2026-08-21. In-app updates are live: 0.3.3 was the first release to carry Sparkle, so anything from 0.3.3 onwards updates itself. Installs older than that need one manual download to catch up. See [docs/releasing.md](docs/releasing.md) for how a release is cut, and [docs/homebrew.md](docs/homebrew.md) for the brew route.

## License

[MIT](LICENSE). Do what you like with it.

Two dependencies and the icon are also MIT, and ship inside the app:
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts),
[Sparkle](https://sparkle-project.org), and Microsoft's
[Fluent Emoji](https://github.com/microsoft/fluentui-emoji) victory hand — see
[docs/brand/vendor/](docs/brand/vendor/) for the licence texts and how each
shipped file is derived. The welcome window's typefaces,
[Syne](https://fonts.google.com/specimen/Syne) and
[Space Grotesk](https://fonts.google.com/specimen/Space+Grotesk), are SIL Open
Font License 1.1 and ship in `Sources/App/Resources/Fonts/` with their licence
texts beside them.

## Design

The product decisions, architecture, and per-service feasibility research behind this app are all written up in [PLAN.md](PLAN.md) — including why each connector works the way it does, what got scoped out (Notion, a push relay, the Mac App Store), and the milestone plan.
