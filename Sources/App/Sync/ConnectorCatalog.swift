import Foundation

/// Static description of every connector kind the app can configure.
/// Settings UI renders add/edit forms from this; secrets go to Keychain as
/// "<sourceID>.<fieldKey>", non-secrets into SourceConfig.settingsJSON.
struct ConnectorKindDescriptor: Sendable, Identifiable {
    struct Field: Sendable, Identifiable {
        var id: String { key }
        var key: String
        var label: String
        var isSecret: Bool
        var placeholder: String = ""
        var help: String = ""
        /// Renders as a checkbox instead of a text field. Stored in
        /// `settingsJSON` as "true"/"false"; an absent key means `defaultOn`.
        var isToggle: Bool = false
        var defaultOn: Bool = false
    }

    var id: String  // kind string used in SourceConfig.kind
    var displayName: String
    var systemImage: String
    var fields: [Field]
    /// False when a second source of this kind would just be a duplicate
    /// view of the same underlying account — a Mac has exactly one Mail.app
    /// database, unlike a GitHub or Linear token, which can name any of
    /// several accounts. The add-source picker disables the kind once one
    /// exists.
    var allowsMultiple: Bool = true
    /// Defaults for new sources of this kind (decision §2.1.4: local
    /// sources banner by default).
    var bannersDefaultOn: Bool = false
    /// How to get the credentials, in the app rather than in a doc nobody
    /// opens. Numbered in order; one short imperative sentence each, and
    /// inline markdown is rendered.
    ///
    /// `authNote` says *why* a source is paste-a-token; these say *how*.
    /// Keeping them apart is what keeps the how brief — the reasoning is
    /// underneath the fields for whoever wants it, and the steps are above
    /// them where you need them.
    var setupSteps: [String] = []
    /// The provider page step 1 refers to, offered as a button.
    var setupURL: String = ""
    /// Something the provider's console asks you to paste, offered as a
    /// Copy button beside the steps.
    var setupPayload: SetupPayload?

    /// Shown in the source editor under the credential fields: why this
    /// provider is paste-a-token rather than OAuth (PLAN §6.9 verdicts).
    var authNote: String = ""

    struct SetupPayload: Sendable {
        var label: String
        var text: String
    }
}

enum ConnectorCatalog {
    static let all: [ConnectorKindDescriptor] = [
        .init(
            id: "linear", displayName: "Linear", systemImage: "line.3.horizontal.decrease.circle",
            fields: [
                .init(
                    key: "apiKey", label: "Personal API Key", isSecret: true,
                    placeholder: "lin_api_…",
                    help: "Linear → Settings → Security & Access → Personal API keys")
            ],
            setupSteps: [
                "Open Linear → Settings → Security & Access.",
                "Under **Personal API keys**, create a key (`lin_api_…`).",
                "Paste it below.",
            ],
            setupURL: "https://linear.app/settings/api",
            authNote: "Why no “Sign in with Linear”? It existed and was removed: OAuth still required registering your own Linear application and pasting its client ID, so it traded one paste for a longer setup and a token that expires. The personal API key is Linear's own sanctioned path for personal use. The key is stored in your Keychain and never leaves this Mac."),
        .init(
            id: "github", displayName: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
            fields: [
                .init(
                    key: "pat", label: "Classic Personal Access Token", isSecret: true,
                    placeholder: "ghp_…",
                    help: "Classic PAT with the `notifications` scope. Fine-grained tokens cannot read notifications."),
                .init(
                    key: "participating", label: "Only where I'm involved", isSecret: false,
                    help: "Mentions, review requests, assignments and threads you've commented on. Off means every notification from every repo you watch — which on a busy org can be thousands.",
                    isToggle: true, defaultOn: true),
            ],
            setupSteps: [
                "In GitHub, go to Settings → Developer settings → **Personal access tokens → Tokens (classic)**.",
                "Generate a token with the **`notifications`** scope.",
                "If your organization enforces SAML SSO, click **Authorize** next to the new token.",
                "Paste it below.",
            ],
            setupURL: "https://github.com/settings/tokens",
            authNote: "Why no “Sign in with GitHub”? GitHub's notifications API only accepts classic personal access tokens — it rejects OAuth app tokens and fine-grained PATs outright. The token is stored in your Keychain and never leaves this Mac."),
        .init(
            id: "slack", displayName: "Slack", systemImage: "number",
            fields: [
                .init(
                    key: "userToken", label: "User OAuth Token", isSecret: true,
                    placeholder: "xoxp-…",
                    help: "From your app's OAuth & Permissions page. Not the “xoxe.xoxp-” app configuration token offered on the apps list — that one is Manifest-API-only and expires in 12 hours."),
                .init(
                    key: "appToken", label: "App-Level Token (optional)", isSecret: true,
                    placeholder: "xapp-…",
                    help: "Socket Mode token with connections:write. Leave blank and Slack still works — you just won't get channel mentions."),
                .init(
                    key: "saveEmoji", label: "Save Emoji", isSecret: false,
                    placeholder: "pushpin",
                    help: "Reacting with this emoji saves a message to the queue"),
                .init(
                    key: "searchTerms", label: "Keyword Watch", isSecret: false,
                    placeholder: "@you, your project, a customer name",
                    help: "Comma-separated. Polls Slack search every 5 minutes and queues matches from the last 24 hours — including public channels you're NOT in, which events can't see and Slack itself won't notify you about. Needs the search:read scope (re-install the app after adding it). Blank turns it off."),
                .init(
                    key: "mutedChannels", label: "Mute Channels", isSecret: false,
                    placeholder: "#random, #deploys",
                    help: "Comma-separated channel names. Nothing from these channels reaches the queue — keyword hits and @-mentions both — so you can watch a term everywhere except the places it means nothing. DMs and emoji saves are never muted."),
            ],
            setupSteps: [
                "Go to api.slack.com/apps → **Create New App** → **From an app manifest**.",
                "Pick your workspace, switch to the **YAML** tab, paste the manifest, and create the app.",
                "**Install to Workspace** — your admin may have to approve it.",
                "**OAuth & Permissions** → copy the **User OAuth Token** (`xoxp-…`) into the field below.",
                "Optional, for channel mentions: **Basic Information → App-Level Tokens → Generate**, scope `connections:write`, and paste that (`xapp-…`) too.",
            ],
            setupURL: "https://api.slack.com/apps",
            setupPayload: .init(label: "App Manifest", text: slackAppManifest),
            authNote: "Why paste tokens? Your workspace app's install page *is* Slack's OAuth flow — it ends by displaying the user token. A native app can't run Slack's OAuth itself: the token exchange requires your client secret (Slack has no PKCE public-client mode), and redirect URLs must be HTTPS, so there's no loopback to come back to. The app-level token never comes from OAuth at all.\n\nOnly the user token is required. Adding the app-level token turns on Socket Mode, which is the only supported way to receive channel mentions — Slack publishes no API for “messages that mention me”, so without it you get DM unreads, emoji saves and read-state auto-clear, but not mentions. Both tokens live in your Keychain and never leave this Mac."),
        .init(
            id: "sentry", displayName: "Sentry", systemImage: "ladybug",
            fields: [
                .init(
                    key: "org", label: "Organization Slug", isSecret: false,
                    placeholder: "acme",
                    help: "The `sentry.io/organizations/<slug>/` part of your URL — not the display name."),
                .init(
                    key: "token", label: "User Auth Token", isSecret: true,
                    placeholder: "sntryu_…",
                    help: "Needs the `event:read` scope, plus `event:write` only if you turn on resolving below."),
                .init(
                    key: "query", label: "Search", isSecret: false,
                    placeholder: SentryConnector.defaultQuery,
                    help: "Sentry search syntax, the same as the issues page. Blank uses `\(SentryConnector.defaultQuery)` — Sentry's own For Review tab, which is already a triage queue."),
                .init(
                    key: "resolveOnDone", label: "Resolve in Sentry when I mark done",
                    isSecret: false,
                    help: "Off by default, because resolving is team-visible — it closes the issue for everyone. Left off, marking done here just means “I've seen this”, and the issue comes back if the error happens again.",
                    isToggle: true, defaultOn: false),
            ],
            setupSteps: [
                "In Sentry, open **Settings → Account → User Auth Tokens**.",
                "Create a token with the **`event:read`** scope (add `event:write` only if you want this app to resolve issues).",
                "Paste it below, along with your organization slug.",
            ],
            setupURL: "https://sentry.io/settings/account/api/auth-tokens/",
            authNote: "Why paste a token? Sentry's own user auth tokens are the sanctioned path for acting as yourself — there is no app to register and nothing to approve. The token is stored in your Keychain and never leaves this Mac.\n\nSentry's REST API is available on every plan including the free Developer tier; what the paid tiers buy is event quota and higher rate limits, not API access."),
        .init(
            id: "appleMail", displayName: "Apple Mail", systemImage: "envelope",
            fields: [
                .init(
                    key: "flagged", label: "Flagged messages", isSecret: false,
                    help: "A message you flagged yourself is the strongest signal an inbox has, so these arrive high-signal. Marking one done marks it read in Mail and clears the flag.",
                    isToggle: true, defaultOn: true),
                .init(
                    key: "unread", label: "Unread messages", isSecret: false,
                    help: "Off by default on purpose: unread-in-inbox is thousands of messages for most people and would bury every other source. Marking one done marks it read in Mail, the same as reading it there.",
                    isToggle: true, defaultOn: false),
                .init(
                    key: "mailbox", label: "Mailbox", isSecret: false,
                    placeholder: "INBOX",
                    help: "Optional. Blank watches Mail's unified inbox across every account. Name one mailbox to narrow it."),
            ],
            allowsMultiple: false,
            setupSteps: [
                "Nothing to paste — this source reads the Mail app that's already on this Mac.",
                "macOS will ask once for permission to control Mail. **Allow it**, or the source stays permanently empty.",
                "Flag a message in Mail and it appears here on the next refresh.",
            ],
            authNote: "No token, and nothing to sign in to: this reads the Mail app on this Mac over AppleScript, so it covers every account Mail has — **including Gmail**, which is why there is no separate Gmail source. Nothing is sent anywhere.\n\nmacOS gates this behind Privacy & Security → Automation. If you decline, Mail looks permanently empty rather than broken, so this source says so explicitly instead of showing you an empty queue.\n\nThe first refresh after Mail has been idle can take around ten seconds — that's Mail waking up, not a failure."),
        .init(
            id: "jsonPoller", displayName: "Custom JSON Feed", systemImage: "curlybraces",
            fields: [
                .init(
                    key: "url", label: "Feed URL", isSecret: false,
                    placeholder: "https://…"),
                .init(key: "authHeader", label: "Authorization Header", isSecret: true,
                    help: "Optional; sent as the Authorization header verbatim"),
                .init(
                    key: "mapping", label: "Field Mapping", isSecret: false,
                    placeholder: "id=id,title=title,url=url,time=created_at",
                    help: "Maps feed JSON keys to item fields"),
            ],
            setupSteps: [
                "Point **Feed URL** at any URL returning a JSON array, or an object with an `items` array.",
                "In **Field Mapping**, name the keys your feed uses: `id=id,title=title,url=link,time=created_at`.",
                "`id` and `title` are required; everything else is optional.",
            ]),
        .init(
            id: "ntfy", displayName: "ntfy", systemImage: "bell.badge",
            fields: [
                .init(
                    key: "server", label: "Server", isSecret: false,
                    placeholder: "https://ntfy.sh",
                    help: "Leave as ntfy.sh, or point at your own instance"),
                .init(
                    key: "topics", label: "Topics", isSecret: false,
                    placeholder: "deploys,alerts",
                    help: "Comma-separated. On an unprotected topic the name is the only thing keeping strangers out — treat it like a password."),
                .init(
                    key: "token", label: "Access Token", isSecret: true,
                    placeholder: "tk_…",
                    help: "Optional — for a protected topic. Takes precedence over username/password below."),
                .init(
                    key: "username", label: "Username", isSecret: false,
                    placeholder: "phil",
                    help: "Optional — use instead of a token if your server only has accounts."),
                .init(
                    key: "password", label: "Password", isSecret: true,
                    help: "Optional — sent as HTTP basic auth alongside the username."),
            ],
            bannersDefaultOn: true,
            setupSteps: [
                "Choose a topic name — on a public server, anyone who guesses it can publish to you, so make it unguessable.",
                "Enter it below, then send yourself one: `curl -d hello ntfy.sh/<topic>`.",
                "Only if your server protects the topic: add a token, or a username and password.",
            ],
            setupURL: "https://ntfy.sh",
            authNote: "No OAuth needed, and none to skip: ntfy has no accounts on unprotected topics — publishing to a topic is the whole API. Priority 4–5 messages arrive as high-signal; `click` becomes the item's link.\n\nFor a protected topic, use either an access token or a username and password — whichever your server is set up for. A token wins if you fill in both, since it's the narrower credential and can be revoked without touching your account password. The token and password are stored in your Keychain and never leave this Mac."),
        .init(
            id: "local", displayName: "Local (Terminal & Claude Code)", systemImage: "terminal",
            fields: [], bannersDefaultOn: true,
            setupSteps: [
                "Nothing to configure — this source only shows what something pushes to it.",
                "From a script or terminal: `inchill notify --title \"Build finished\"`.",
                "For Claude Code, turn on the hooks in Settings → General.",
            ]),
    ]

    /// The Slack app manifest, offered as a Copy button in the source
    /// editor. Setting twelve user scopes and six event subscriptions by
    /// hand is the step that makes people give up — and get wrong.
    ///
    /// Derived mechanically from `docs/slack-app-manifest.yml`, which is the
    /// annotated source of truth and carries the reasoning for every scope
    /// and the note about which event types Slack's validator rejects.
    /// **Change that file and re-derive this**, never the other way round:
    /// that file is the one that has actually been through Slack's
    /// validator.
    static let slackAppManifest = """
        display_information:
          name: Inbox and Chill
          description: "Surfaces my own mentions, unread DMs and emoji-saved messages in a private menu bar app. Acts only on my own account."
          background_color: "#2b2d31"
        oauth_config:
          scopes:
            user:
              - channels:read
              - channels:history
              - groups:read
              - groups:history
              - im:read
              - im:history
              - mpim:read
              - mpim:history
              - users:read
              - reactions:read
              - reactions:write
              - search:read
        settings:
          event_subscriptions:
            user_events:
              - message.channels
              - message.groups
              - message.im
              - message.mpim
              - reaction_added
              - reaction_removed
          interactivity:
            is_enabled: false
          org_deploy_enabled: false
          socket_mode_enabled: true
          token_rotation_enabled: false
        """

    static func descriptor(for kind: String) -> ConnectorKindDescriptor? {
        all.first { $0.id == kind }
    }
}

/// Convenience for connector settings stored in SourceConfig.settingsJSON.
extension SourceConfig {
    var settings: [String: String] {
        get {
            settingsJSON.flatMap {
                try? JSONDecoder().decode([String: String].self, from: $0)
            } ?? [:]
        }
        set { settingsJSON = try? JSONEncoder().encode(newValue) }
    }
}


extension ConnectorKindDescriptor.Field {
    /// Resolves this toggle against stored settings, honouring `defaultOn`
    /// when the key was never written.
    func boolValue(in settings: [String: String]) -> Bool {
        // Absent *or* empty both mean "never actually set" — the editor sheet
        // can persist an empty string for an untouched field, and reading that
        // as `false` would silently flip the setting away from what the
        // checkbox is showing.
        guard let raw = settings[key], !raw.isEmpty else { return defaultOn }
        return raw == "true"
    }
}
