# Inbox & Chill

A native macOS menu bar app that pulls your unread/actionable items from Linear, GitHub, Slack, Campsite, custom JSON feeds, and your terminal (including Claude Code) into one queue — and then helps you empty it.

Inbox & Chill is a **triage queue, not a status mirror**. It doesn't try to be a client for any of these services — no composing Slack messages, no editing Linear issues. Items flow in, you act on them (open, done, snooze, pin, archive), and the queue goes to zero. The moment an item needs real work, it deep-links you into the app that owns it. The menu bar is the primary surface: click the icon (or hit a global hotkey) and a panel drops down with everything waiting for you, grouped by source.

## Features

**Sources**
- Linear — full inbox mirror (mentions, assignments, comments), with real remote snooze
- GitHub — notifications inbox (review requests, mentions, assignments)
- Slack — mentions and unreads via Socket Mode, plus an emoji-reaction "save for later"
- Campsite — self-hosted internal API (notifications + follow-ups)
- ntfy — push notifications over a topic's WebSocket
- Custom JSON feeds — point it at any URL that returns a JSON array (or `{items: [...]}`)
- Terminal / Claude Code — local push from shell commands and Claude Code hooks

**Two surfaces**
The menu bar panel is the default: click the icon (or hit a global hotkey) and it drops down over everything waiting for you, grouped by source. `⌘0` (or the window icon in the footer) opens the same queue as a regular window instead, with every triage action mirrored as a real menu item under **Queue** — useful for keeping it around on a second display.

**The selected row opens**
Every row is one line until you move onto it, and then it opens to a paragraph — two lines of title, four of message — and closes again as you arrow past. One line is enough to tell items apart and rarely enough to act on one, so the row you are actually looking at is the one that shows its text.

**Automation**
Siri Shortcuts / App Intents expose the queue outside the app: get items, get a count, snooze, or mark done from Shortcuts.app, Spotlight, or a voice command.

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

The build also compiles and embeds the `inchill` CLI inside the app bundle (`Contents/MacOS/inchill`), signed with the same identity — see [docs/shell-integration.md](docs/shell-integration.md).

## Status

This is a personal tool, built for one person's daily use, and pre-release. Expect rough edges, and expect the shape of things (especially per-source setup) to shift. It's planned for eventual open-source release on GitHub; if you're reading this from a clone, you're early.

## License

TBD.

## Design

The product decisions, architecture, and per-service feasibility research behind this app are all written up in [PLAN.md](PLAN.md) — including why each connector works the way it does, what got scoped out (Notion, a push relay, Apple Reminders), and the milestone plan.
