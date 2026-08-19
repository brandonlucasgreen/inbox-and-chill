# Security posture: credentials

Audited 2026-08-17. The rule (PLAN §4.3): **every secret lives in the
Keychain; nothing sensitive touches UserDefaults, SwiftData, plain files, or
logs.** This documents where each credential lives, how it travels, and what
the audit fixed.

## Where secrets live

| Secret | Storage | Notes |
|---|---|---|
| Linear personal API key | Keychain `<sourceID>.apiKey` | |
| Linear OAuth access/refresh tokens | Keychain `<sourceID>.oauthAccessToken` / `.oauthRefreshToken` / `.oauthExpiresAt` | Written by the PKCE flow; refreshed in place |
| GitHub classic PAT | Keychain `<sourceID>.pat` | |
| Slack user + app tokens | Keychain `<sourceID>.userToken` / `.appToken` | |
| JSON poller auth header | Keychain `<sourceID>.authHeader` | |
| Local listener bearer token | In-memory + `~/Library/Application Support/InboxAndChill/local-api.json` (0600) | See below |

Keychain items are marked `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
never synced by iCloud Keychain, never migrated to another device.

Writes always **delete then add**, never `SecItemUpdate` — an update
preserves the item's existing access control list, so an item created by a
differently-signed build would keep trusting that dead identity forever and
re-prompt on every read. Deleting first means the replacement item's ACL is
authored by the running build.

**Secrets are cached in process memory** after their first read
(`Keychain.SecretCache`), because connectors ask for their token on every
poll and every triage action — without a cache, an item whose ACL doesn't
name the running app produces an authorization panel every 30 seconds.
The tokens are already resident in memory whenever a request is in flight,
so this widens exposure to the process lifetime rather than adding a new
class of risk. All writes go through `set`/`delete`, so the cache cannot
drift from the Keychain.

## Invariants (hold everywhere, checked in the audit)

- **Tokens travel only in `Authorization` headers**, over HTTPS, to each
  provider's own API host. Never in URL query strings, never in bodies
  (except the OAuth token exchange, which is the protocol), never to any
  host the user didn't configure.
- **No secret is ever logged.** The app has no logging of request headers;
  error messages embed HTTP status + response-body snippets (provider error
  JSON — no echo of credentials), never the request.
- **Secrets are never read back into the UI.** The source editor's secret
  fields render blank in edit mode; leaving one blank keeps the stored
  value. The UI only ever checks *existence* of a Keychain item.
- **SwiftData stores non-secrets only** (`SourceConfig.settingsJSON`:
  emoji, URLs, org slugs, the OAuth *client ID* — which is public by
  design in PKCE).
- **Deleting a source prefix-wipes the Keychain** (`Keychain.deleteAll
  (prefix: "<sourceID>.")`), so no credential outlives its source — even
  ones from an auth method the source no longer uses.
- **Pasteboard/drag payloads** contain item titles and deep-link URLs only.
- **Claude Code hook install** writes only the `inchill` executable path
  into `~/.claude/settings.json` — no token; the CLI reads the rotating
  discovery file at invocation time.

## The local listener token

The localhost listener (terminal/Claude Code push) can't use the Keychain
for its handshake — the `inchill` CLI is a separate binary and a Keychain
read from it would prompt on every hook fire. Instead:

- The bearer token is **generated fresh on every app launch**
  (`SecRandomCopyBytes`) — a leaked token dies with the session.
- The discovery file is created **with `0600` permissions atomically** (no
  write-then-chmod window).
- The listener binds `127.0.0.1` only; every request without the exact
  bearer token gets a 401.

## OAuth: none, anywhere

Every source is paste-a-token. Linear had a PKCE loopback flow until
2026-08-19 (removed — see PLAN §6.9), and with it went the only listener the
app ever opened for authentication. The only socket it binds now is the
local push API described above.

## Known accepted risks

- The local-api.json token is same-user-readable plaintext for one app
  session. Accepted: it only authorizes inserting/clearing items in the
  local queue on the same machine, and rotation bounds its life.
- Personal API keys/PATs are long-lived by nature; the Keychain is the
  mitigation, and every provider's own console can revoke one. There is no
  shorter-lived alternative for any of the six sources — the paths that
  offered one were removed or never existed (PLAN §6.9).
