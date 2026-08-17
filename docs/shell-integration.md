# Shell & Claude Code integration

Inbox & Chill runs a localhost HTTP listener (bearer-token protected, random port) so anything on the same machine — a shell command, a build script, Claude Code — can push items into the triage queue without any cloud infrastructure. The `inchill` CLI is the client for that listener.

## The `inchill` CLI

`inchill` ships inside the app bundle at:

```
/Applications/Inbox & Chill.app/Contents/MacOS/inchill
```

It's a standalone, dependency-free binary — it doesn't link against the app, it just talks to the localhost listener over HTTP. To use it as a plain shell command, add an alias or a symlink somewhere on your `PATH`:

```sh
# alias (put in ~/.zshrc)
alias inchill='/Applications/Inbox & Chill.app/Contents/MacOS/inchill'

# or a symlink
ln -s "/Applications/Inbox & Chill.app/Contents/MacOS/inchill" /usr/local/bin/inchill
```

`inchill` discovers the running app by reading `~/Library/Application Support/InboxAndChill/local-api.json` for the current port and token, so it always finds the right instance as long as the app is running with local sources enabled.

### Usage

```
inchill notify [--id X] [--source S] [--kind K] --title T [--body B] [--url U] [--low]
inchill done <id>
inchill clear <id>
inchill claude-hook <notification|stop>
```

- **`notify`** — pushes a new item into the queue.
  - `--title` is required (if omitted, it's read from stdin instead).
  - `--id` sets a stable external ID; if you reuse an ID, it upserts rather than duplicating.
  - `--source` / `--kind` label where the item came from (defaults to a generic local source).
  - `--body` and `--url` populate the snippet and deep-link.
  - `--low` marks the item low-signal (it won't count toward the high-signal badge count, and local sources otherwise default to high-signal banners).

  ```sh
  inchill notify --title "make: done (exit 0)"
  inchill notify --title "Deploy finished" --url "https://ci.example.com/builds/42" --low
  echo "Nightly backup complete" | inchill notify
  ```

- **`done <id>`** / **`clear <id>`** — both clear an item by its external ID (two names for the same operation; use whichever reads better in a script).

  ```sh
  long_running_build; inchill done "nightly-build"
  ```

- **`claude-hook <notification|stop>`** — reads a Claude Code hook's JSON payload from stdin and translates it into the calls above. See below.

## Claude Code hooks

Claude Code fires two hooks relevant here:

- **`Notification`** — fires exactly when a session wants you: a permission prompt, or Claude idling while waiting for input. `inchill claude-hook notification` turns this into a **high-signal** item (`id: claude-<session_id>`, source `claude-code`, kind `claude_waiting`) so a blocked session doesn't sit unnoticed.
- **`Stop`** — fires when a turn ends and it's your turn again. `inchill claude-hook stop` does two things: it **clears** the waiting item from the `Notification` hook (the wait is over), and it leaves behind a fresh **low-signal** breadcrumb (kind `claude_done`, titled `"Claude finished in <folder>"`) so a finished-but-unattended session still shows up in the queue, just without banging on the high-signal badge.

### Setting it up

The easiest path is the app's own **"Set up Claude Code integration"** button (Settings → Sources → Local), which writes the hook entries for you. It merges into `~/.claude/settings.json` non-destructively — any other hooks or settings you have are preserved verbatim, and the pre-existing file is backed up to a timestamped sibling (`settings.json.inchill-backup-<epoch>`) before every write.

To do it by hand instead, add this shape to `~/.claude/settings.json` (merge it into your existing `hooks` object rather than replacing it):

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "/Applications/Inbox & Chill.app/Contents/MacOS/inchill claude-hook notification" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "/Applications/Inbox & Chill.app/Contents/MacOS/inchill claude-hook stop" }
        ]
      }
    ]
  }
}
```

If you installed `inchill` to `/usr/local/bin` instead of using the bundled copy, use `inchill claude-hook notification` / `inchill claude-hook stop` as the command — the app's own installer prefers the bundled binary (so hooks survive app updates) and falls back to `/usr/local/bin/inchill` otherwise.

## Plain shell / zsh integration

Outside of Claude Code, there's no notification API for a stock terminal to hook into, so the integration is a `precmd`/`preexec` pair: time every command, and report it to `inchill` when it finishes if it ran longer than a threshold (30 seconds below). Add this to `~/.zshrc`:

```zsh
INCHILL_CMD_START=0
INCHILL_CMD_NAME=""
INCHILL_NOTIFY_THRESHOLD=30

inchill_preexec() {
  INCHILL_CMD_START=$SECONDS
  INCHILL_CMD_NAME=$1
}

inchill_precmd() {
  local exit_code=$?
  if [[ $INCHILL_CMD_START -gt 0 ]]; then
    local elapsed=$(( SECONDS - INCHILL_CMD_START ))
    if (( elapsed >= INCHILL_NOTIFY_THRESHOLD )); then
      inchill notify --low --title "${INCHILL_CMD_NAME} (exit ${exit_code}, ${elapsed}s)"
    fi
  fi
  INCHILL_CMD_START=0
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec inchill_preexec
add-zsh-hook precmd inchill_precmd
```

Notes on this snippet:
- `preexec` runs right before a command executes and records `$SECONDS` (zsh's built-in elapsed-seconds counter) and the command line; `precmd` runs right after, once the prompt is about to redraw, and does the reporting.
- `$?` is captured as the very first thing in `inchill_precmd` — before any other command runs and clobbers it — so the exit status reported is the finished command's, not some intermediate one.
- Guarding on `INCHILL_CMD_START -gt 0` means a bare `Enter` on an empty line (no `preexec` fired) won't spuriously fire the hook.
- Use `add-zsh-hook` rather than assigning `precmd`/`preexec` directly, so this composes with any other tool (like a prompt theme) that also hooks those.

You can also invoke `inchill` directly for one-off cases, independent of the `precmd` hook:

```sh
long_command; inchill done "deploy finished"
```
