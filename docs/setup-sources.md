# Setting up sources

Each source is added from Settings → Sources → Add. This walks through the exact fields each one asks for and where to get them.

## Linear

**Field:** Personal API Key

1. In Linear, go to **Settings → API**.
2. Under **Personal API keys**, create a new key (`lin_api_…`).
3. Paste it into the source's **Personal API Key** field.

A "Sign in with Linear" OAuth option existed until 2026-08-19 and was removed: it still required registering your own Linear application and pasting its client ID, so it traded one paste for a longer setup and a token that expires. See PLAN §6.9.

That's the whole setup. Linear is polled every 30–60 seconds and is a true 1:1 mirror of your Linear inbox — mentions, assignments, comments — with full write-through: marking an item done in Inbox & Chill marks it read in Linear, and snoozing is a real remote snooze, not a local approximation.

## GitHub

**Fields:** Classic Personal Access Token

1. In GitHub, go to **Settings → Developer settings → Personal access tokens → Tokens (classic)**.
2. Generate a new token with the **`notifications`** scope.
3. Paste it into the source's **Classic Personal Access Token** field.

**Why classic, not fine-grained:** as of 2026 fine-grained PATs still have no permission at all for the notifications API — there's simply no scope to grant. A classic token with `notifications` is the only way in. Gitify, Trailer, and every other GitHub-notifications tool hits this same wall.

**SSO note:** if your organization enforces SAML SSO on personal access tokens, a freshly created classic PAT won't be able to see that org's notifications until you authorize it — look for an **"Enable SSO"** / **"Authorize"** link next to the token on the tokens page and click through it once.

**Only where I'm involved** (on by default) adds `participating=true`, which limits the feed to threads you're actually in — mentioned, assigned, review requested, authored, or already commented on. Turn it off and you get every notification from every repo you watch.

That distinction is not a nicety. On one real account the split was **1,187 `subscribed` notifications against 12 that actually involved the user** — 99% monorepo noise. A triage queue full of other people's PR activity is not a triage queue.

Two things follow from it:

- **GitHub caps `/notifications` at 50 per page** — that is both the default *and* the maximum — so the app pages through (up to 1,000). If you ever exceed that, remote-truth archiving is suspended for the cycle rather than archiving the notifications it simply couldn't fetch. Before this was handled, everything past #50 was auto-archived and then resurrected as the window slid, so items could never be dismissed for good.
- **Turning the toggle on retroactively clears the noise.** Items no longer in the feed are absent from the next snapshot and auto-archive themselves — a bulk cleanup for free. Turning it back off brings them back, since they reappear in the feed.

## Slack

**Fields:** User OAuth Token, App-Level Token (optional), Save Emoji

Slack setup has more steps because you're creating your own Slack app rather than pasting in a single key.

1. Go to **https://api.slack.com/apps → Create New App → From an app manifest**, pick your workspace, and paste in the contents of [`docs/slack-app-manifest.yml`](slack-app-manifest.yml).
2. Click **Install to Workspace**. If your workspace has "Require App Approval" turned on, this queues an approval request instead of installing immediately — a workspace admin will need to approve it before the app can be used. (It's a read-only app that only ever acts on your own account, which tends to be an easy approval to ask for.)
3. Once installed, collect your tokens:
   - **User OAuth Token** (`xoxp-…`) — on the app's **OAuth & Permissions** page, under "OAuth Tokens for Your Workspace". **Required.**

     **Not the token at the top of the apps list.** `api.slack.com/apps` also offers **App Configuration Tokens**, which look like `xoxe.xoxp-…`. Those drive the App Manifest API only, expire 12 hours after you generate them, and cannot call the Web API at all — easy to grab by mistake, since "generate a token" is right there. The app checks the prefix and tells you which one you've pasted rather than failing with a Slack error that explains nothing.

     The same `xoxe.` prefix also appears if you enable **token rotation**: those expire every 12 hours and can only be refreshed with your app's client secret, which a native app can't hold. Slack does not allow rotation to be turned off once enabled, so if that happened you need a new app. The manifest in this repo sets `token_rotation_enabled: false` for exactly that reason.
   - **App-Level Token** (`xapp-…`) — on **Basic Information → App-Level Tokens → Generate**, with the `connections:write` scope. **Optional**, and what it buys you is explained below.
4. Paste the user token in; add the app-level token too if you want channel mentions.
5. **Save Emoji** defaults to `pushpin` (📌). This is the emoji you react with to save a message — see below.

**What you get:** mentions and unreads across channels, groups, and DMs, delivered in real time over Socket Mode. Marking an item done in the app marks it read in Slack.

**Why is there no "Sign in with Slack"?** Because a native Mac app can't do Slack's OAuth. Two independent blockers: the token exchange at `oauth.v2.access` requires your app's **client secret** (Slack has no PKCE public-client mode, unlike Linear), and every Redirect URL **must be HTTPS** — `http://localhost` is rejected, so there's no loopback for the browser to come back to. Shipping a client secret inside a distributed app would just leak it. A proper sign-in button would need a hosted relay to hold the secret and do the exchange, which is the deferred Cloudflare relay idea. Your app's install page already *is* the OAuth consent screen; it just hands you the token at the end instead of redirecting.

**If you skip the app-level token,** the source still works — you get DM and group-DM unreads, emoji saves, and read-state auto-clear, all by polling. What you lose is **channel mentions**, and that's not a shortcut we chose: Slack publishes no API for "messages that mention me". Its search API has no mention modifier at all (`from:`, `in:`, `has:`, `with:` — but nothing for mentions), and the Mentions & reactions view in Slack's own client runs on a private endpoint. Socket Mode's event stream is the only supported way to learn that you were mentioned, which is the one thing the second token unlocks.

**What you don't get: Slack's "Saved for Later."** There is no API for it — `stars.list` is deprecated and frozen, and Slack has said outright that Later APIs aren't available. The emoji-save feature is the replacement: react to any message with your Save Emoji and it shows up as an item in Inbox & Chill (with a link back to the message); remove the reaction and it clears. It needs no extra setup beyond the emoji field above, since the same Socket Mode connection that watches for mentions also watches for `reaction_added`/`reaction_removed`.

**One thing to expect:** channel mentions only appear for activity happening *after* you set the source up — they arrive as events, and there's no history API to backfill them from (see above). DM unreads and emoji saves *are* backfilled, because both have real polling endpoints (`conversations.info` and `reactions.list`).

## Custom JSON feed

**Fields:** Feed URL, Authorization Header (optional), Field Mapping

For any internal tool or script that can serve a JSON list, add it as a custom source:

1. **Feed URL** — any URL that returns either a bare JSON array, or an object with an `items` array.
2. **Authorization Header** — optional; if set, it's sent verbatim as the request's `Authorization` header (e.g. `Bearer sometoken`).
3. **Field Mapping** — a comma-separated list of `ourField=theirField` pairs telling the app how to read your JSON. Supported fields:
   - `id=` — a stable identifier (falls back to `url=` if omitted)
   - `title=` — required
   - `url=` — deep-link target
   - `time=` — an ISO 8601 timestamp
   - `body=` — a snippet/description

   Example mapping: `id=id,title=title,url=html_url,time=created_at,body=description`

This source is polled every two minutes. Example feed JSON that the mapping above would consume:

```json
[
  {
    "id": "42",
    "title": "Deploy failed on staging",
    "html_url": "https://ci.example.com/builds/42",
    "created_at": "2026-08-17T14:32:00Z",
    "description": "Step 'run tests' exited 1"
  }
]
```

An `{ "items": [...] }` wrapper works the same way.

## ntfy

**Fields:** Server, Topics, Access Token (optional)

[ntfy](https://ntfy.sh) is a pub/sub notification service: anything that can make an HTTP request can push you a notification. It's the easiest source here to set up and the easiest to feed from your own scripts.

1. Pick a topic name. Anything you like — but on the public server the name is the **only** thing keeping strangers out, so make it unguessable (`deploys-3f9a2c81`, not `deploys`).
2. Add an **ntfy** source. Leave **Server** as `https://ntfy.sh`, or point it at your own instance.
3. Put your topic in **Topics**. Several are fine, comma-separated: `deploys-3f9a2c81,alerts-77b1`.
4. Credentials are optional — an unprotected topic needs none. For a protected one, fill in **either**:
   - **Access Token** (`tk_…`), from `ntfy token add` on a self-hosted instance or your ntfy.sh account; or
   - **Username** and **Password**, if your server only has accounts.

   Both filled in? The token wins — it's the narrower credential and can be revoked without touching your account password. Half a basic credential (username but no password, or vice versa) is treated as none at all, because sending half would only ever fail.

   **A wrong credential is worse than no credential.** ntfy answers `401` even on a topic that would have worked anonymously, so if a public topic stops arriving after you type a password, clear both fields rather than trying to fix them. The app names that specific case in the source's error rather than sitting in "connecting…" — a typo'd password is a configuration problem, not a flaky network, and it shouldn't look like one.

Publish to it from anything:

```bash
curl -H "Title: Deploy finished" -H "Priority: 4" \
     -H "Click: https://ci.example.com/builds/42" \
     -d "web@a1b2c3 is live" \
     https://ntfy.sh/deploys-3f9a2c81
```

**How ntfy fields map to items:** `title` becomes the item title (with `message` as the snippet); with no `title`, the message body becomes the title. `click` becomes the item's link — so ⏎ on the item opens your build, dashboard, or wherever. `priority` 4 (high) and 5 (max) arrive as **high-signal**, so they count toward the badge and can raise a banner; 1–3 stay quiet. `topic` shows as the item's actor, which is how you tell several topics apart inside one source.

**No OAuth, and none missing:** ntfy has no accounts to sign into on unprotected topics. Publishing to a topic *is* the whole API. The token and password live in your Keychain; the username, being non-secret, sits with the rest of the source's settings.

**What you don't get:** there's no read-state to sync back — ntfy messages are fire-and-forget events, not rows in a remote inbox. So items stay until you mark them done, exactly like terminal and Claude Code items.

**Nothing is lost to a dropped connection.** ntfy caches recent messages server-side, and the app reconnects with `since=<last message id>` — an exclusive cursor, so you get precisely the messages you missed and no duplicates. On a cold start it reaches back 12 hours; replaying an item you've already dealt with is harmless, because items are keyed on the ntfy message id and an already-done item stays done.

---

# Journal export (Obsidian daily notes)

Not a source — an *output*. With this on, Inbox & Chill appends a line to a Markdown file every time something arrives and every time you act on it. Point it at your Obsidian daily note and you get a durable record of what came in and what you did, which is exactly the raw material an agent needs to reflect on your week.

**Settings → General → Journal.**

| Field | What it does |
| --- | --- |
| **File** | Absolute path. `{{YYYY}}`, `{{MM}}` and `{{DD}}` become today's date — the same tokens Obsidian's daily notes use, so the format string you already have there works here. Missing folders are created. |
| **Heading** | Entries go under this heading, so they sit tidily inside a templated note. Created at the end of the file if absent. Defaults to `## Inbox & Chill`. |
| **Log items when they arrive** | One line per new item. |
| **Log what you do with them** | One line per done, snooze, pin, unpin, or restore. |

A typical path:

```
~/Vault/daily-notes/{{YYYY}}-{{MM}}-{{DD}}.md
```

What it writes:

```markdown
## Inbox & Chill

- 09:41 · **arrived** · Linear · [Fix the flaky sync test](https://linear.app/x/ISS-1)
- 09:52 · **done** · Linear · [Fix the flaky sync test](https://linear.app/x/ISS-1) · waited 11m
- 10:03 · **snoozed** · GitHub · [Review requested on #412](https://github.com/x/y/pull/412) · until 8/18/26, 2:00 PM
- 14:00 · **pinned** · Slack · Ship note from Ana
```

**The format is deliberately rigid** so both you and an agent can read it: `- HH:mm · **action** · Source · Title-or-link · optional detail`. The timestamp is always 24-hour and locale-independent — a journal that renders `09:41` for one person and `9:41 AM` for another is a journal nothing can parse reliably. Titles are flattened to one line and `[`/`]` become `(`/`)`, so a pasted multi-line Slack message can't turn into five bullets or break the link around it.

**`waited` is the interesting field.** On every done, the journal records how long the item sat in your queue — `waited 11m`, `waited 3h 12m`, `waited 2d 4h`. Anything under a minute is left off as noise. That's the number worth reflecting on: not what you did, but what you sat on.

**Actions taken through Shortcuts or Siri are logged too**, because the App Intents call the same code path the panel does.

**Two things to know:**

- **Writing into `~/Documents` (or `~/Desktop`) triggers a one-time macOS permission prompt** for Files and Folders access. Because the app is Developer ID signed and lives at a stable `/Applications` path, that grant sticks rather than re-prompting on every rebuild. A path elsewhere in your home folder needs no prompt.
- **An Obsidian vault synced through iCloud needs Full Disk Access.** Those vaults live at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<Vault>/`, which is *Obsidian's* iCloud container. macOS won't let one app reach into another's container, and — unlike the Documents folder — **no permission prompt appears**; the write simply fails. Two ways out: grant Inbox & Chill **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access), or keep the vault somewhere outside iCloud. The app tells you which of these you're hitting: the error under Journal settings names the container case explicitly.

  Note the path also contains literal tildes (`iCloud~md~obsidian`). Only a *leading* `~` is expanded, so paste the path as-is — the inner tildes are real directory-name characters.
- **Failures are shown, not swallowed.** If a write fails — permission denied, unusable path — the reason appears in red under the Journal settings, and writing resumes automatically once it's fixed.
