# Setting up sources

Each source is added from Settings → Sources → Add. This walks through the exact fields each one asks for and where to get them.

## Linear

**Fields:** Personal API Key

1. In Linear, go to **Settings → API**.
2. Under **Personal API keys**, create a new key (`lin_api_…`).
3. Paste it into the source's **Personal API Key** field.

That's the whole setup. Linear is polled every 30–60 seconds and is a true 1:1 mirror of your Linear inbox — mentions, assignments, comments — with full write-through: marking an item done in Inbox & Chill marks it read in Linear, and snoozing is a real remote snooze, not a local approximation.

## GitHub

**Fields:** Classic Personal Access Token

1. In GitHub, go to **Settings → Developer settings → Personal access tokens → Tokens (classic)**.
2. Generate a new token with the **`notifications`** scope.
3. Paste it into the source's **Classic Personal Access Token** field.

**Why classic, not fine-grained:** as of 2026 fine-grained PATs still have no permission at all for the notifications API — there's simply no scope to grant. A classic token with `notifications` is the only way in. Gitify, Trailer, and every other GitHub-notifications tool hits this same wall.

**SSO note:** if your organization enforces SAML SSO on personal access tokens, a freshly created classic PAT won't be able to see that org's notifications until you authorize it — look for an **"Enable SSO"** / **"Authorize"** link next to the token on the tokens page and click through it once.

## Slack

**Fields:** User OAuth Token, App-Level Token, Save Emoji

Slack setup has more steps because you're creating your own Slack app rather than pasting in a single key.

1. Go to **https://api.slack.com/apps → Create New App → From an app manifest**, pick your workspace, and paste in the contents of [`docs/slack-app-manifest.yml`](slack-app-manifest.yml).
2. Click **Install to Workspace**. If your workspace has "Require App Approval" turned on, this queues an approval request instead of installing immediately — a workspace admin will need to approve it before the app can be used. (It's a read-only app that only ever acts on your own account, which tends to be an easy approval to ask for.)
3. Once installed, collect two tokens:
   - **User OAuth Token** (`xoxp-…`) — on the app's **OAuth & Permissions** page.
   - **App-Level Token** (`xapp-…`) — on **Basic Information → App-Level Tokens → Generate**, with the `connections:write` scope (this is what lets the app use Socket Mode instead of polling).
4. Paste both into the source's fields.
5. **Save Emoji** defaults to `pushpin` (📌). This is the emoji you react with to save a message — see below.

**What you get:** mentions and unreads across channels, groups, and DMs, delivered in real time over Socket Mode (no polling). Marking an item done in the app marks it read in Slack.

**What you don't get: Slack's "Saved for Later."** There is no API for it — `stars.list` is deprecated and frozen, and Slack has said outright that Later APIs aren't available. The emoji-save feature is the replacement: react to any message with your Save Emoji and it shows up as an item in Inbox & Chill (with a link back to the message); remove the reaction and it clears. It needs no extra setup beyond the emoji field above, since the same Socket Mode connection that watches for mentions also watches for `reaction_added`/`reaction_removed`.

**One thing to expect:** because this connector is event-driven rather than a full history backfill, items only appear for activity (mentions, unreads, emoji-saves) that happens *after* you've set the source up — it won't retroactively surface things from before installation.

## Campsite

**Fields:** Base URL, Organization Slug, Access Token

Campsite here means a **self-hosted** instance running the open-source Campsite codebase — this connector talks to the same internal v1 API the Campsite web app itself uses, not the public v2 bot API (which can't see your inbox at all).

1. **Base URL** — the root of your instance, e.g. `https://campsite.buffer.com`.
2. **Organization Slug** — the org segment in your Campsite URLs (e.g. the `buffer` in `campsite.buffer.com/buffer/...`).
3. **Access Token** — a Doorkeeper (OAuth2) bearer token for your account. This isn't self-serve: since v1 auth is first-party/session-based, **you'll need an admin of your Campsite instance to register a Doorkeeper OAuth app** on the instance so you can obtain a token. If your organization already runs an internal tool or MCP server against Campsite, whoever maintains that has almost certainly solved this exact problem already — ask them.

Once configured, this source polls notifications and follow-ups every 60 seconds and writes through on done (it archives the notification, or deletes the follow-up, on Campsite's side).

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
