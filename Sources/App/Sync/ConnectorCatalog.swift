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
    /// Only for a source that asks for a credential. A source with nothing
    /// to fetch gets none — steps there could only restate the access
    /// section below them, which is the duplication Brandon called out on
    /// 2026-08-26 (Reminders) and again on 2026-09-05 (Mail, and the rest).
    var setupSteps: [String] = []
    /// The provider page step 1 refers to, offered as a button.
    var setupURL: String = ""
    /// Something the provider's console asks you to paste, offered as a
    /// Copy button beside the steps.
    var setupPayload: SetupPayload?

    /// One or two sentences the fields cannot say: what this source will
    /// actually put in the queue, or the one behaviour that surprises
    /// people. Rendered under the fields, with inline markdown.
    ///
    /// Deliberately **not** a place for "why a token rather than OAuth".
    /// That reasoning is real, and it lives in PLAN §6.9 and the connector
    /// headers — but it was 789 words spread across these thirteen screens
    /// until 2026-09-05, answering a question nobody standing in front of a
    /// token field is asking. Nor is it the place to say where the secret
    /// is kept: `SourceEditorSheet` states that once, under the fields of
    /// every kind that has one.
    var sourceNote: String = ""

    /// One line on what connecting this kind asks of the user, shown under
    /// the kind picker *before* any field asks it. Nil derives it: a kind
    /// with a secret field is "paste a token", one without is "nothing to
    /// set up". Set it where the derivation would undersell the work —
    /// Slack needs an app created first, and that is the one a first-time
    /// buyer should not pick blind.
    var setupCost: String? = nil

    var setupCostLabel: String {
        if let setupCost { return setupCost }
        if fields.contains(where: \.isSecret) {
            return "You'll paste a token from \(displayName)."
        }
        return "Nothing to set up — no account or token needed."
    }

    /// How this kind's rows fold in the panel when auto-grouping is on, or
    /// nil when there is nothing to fold by (a Claude Code session is already
    /// one row; a custom JSON feed has no natural key). A kind with a
    /// `Grouping` gets a "Group" checkbox in the Sources pane; one without
    /// gets no checkbox rather than one that does nothing.
    struct Grouping: Sendable {
        /// What one fold is — "channel", "issue", "repository" — for the one
        /// sentence of help the checkbox carries.
        var noun: String
        /// On for the sources whose folds are noise (a channel's keyword
        /// hits, a repository's threads); off for to-do sources, where a
        /// fold hides work.
        var defaultOn: Bool
    }
    var grouping: Grouping? = nil

    /// What `C` says on a row of this kind. A to-do is *completed*; a mail
    /// message is *archived*. Same capability (`completesTask`), same key,
    /// different word — and the word has to be the source's own, or the
    /// button promises something the source will not do.
    struct CompleteVerb: Sendable {
        /// Row hover button and accessibility label.
        var button: String
        /// Context menus and the archive pane.
        var menu: String
        /// Tooltip; ends with the key.
        var help: String

        static let complete = CompleteVerb(
            button: "Complete task", menu: "Complete Task",
            help: "Complete it in its app (C)")
    }
    var completeVerb: CompleteVerb = .complete

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
                    help: "")
            ],
            setupSteps: [
                "Open Linear → Settings → Security & Access.",
                "Under **Personal API keys**, create a key (`lin_api_…`).",
                "Paste it below.",
            ],
            setupURL: "https://linear.app/settings/api",
            grouping: .init(noun: "issue or project", defaultOn: true)),
        .init(
            id: "github", displayName: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right",
            fields: [
                .init(
                    key: "pat", label: "Classic Personal Access Token", isSecret: true,
                    placeholder: "ghp_…",
                    help: "Fine-grained tokens can't read notifications."),
                .init(
                    key: "participating", label: "Only where I'm involved", isSecret: false,
                    help: "Off means every notification from every repo you watch.",
                    isToggle: true, defaultOn: true),
            ],
            setupSteps: [
                "In GitHub, go to Settings → Developer settings → **Personal access tokens → Tokens (classic)**.",
                "Generate a token with the **`notifications`** scope. (For private repo notifications, also include the **`repo`** scope.)",
                "If your organization enforces SAML SSO, click **Authorize** next to the new token.",
                "Paste it below.",
            ],
            setupURL: "https://github.com/settings/tokens",
            setupCost: "You'll paste a classic personal access token. An organization with SSO asks you to authorize it once.",
            grouping: .init(noun: "repository", defaultOn: true)),
        .init(
            id: "gitlab", displayName: "GitLab", systemImage: "triangle",
            fields: [
                .init(
                    key: "token", label: "Personal Access Token", isSecret: true,
                    placeholder: "glpat-…",
                    help: "`read_api` can read this queue but not clear it."),
                .init(
                    key: "host", label: "GitLab URL", isSecret: false,
                    placeholder: GitLabConnector.defaultHost,
                    help: "Blank means gitlab.com. Set it for a self-managed instance."),
            ],
            setupSteps: [
                "In GitLab, open **Preferences → Access tokens**.",
                "Add a token with the **`api`** scope. GitLab makes you pick an expiry date — a year is the maximum, and this source will say so when it lapses.",
                "Paste it below.",
            ],
            setupURL: "https://gitlab.com/-/user_settings/personal_access_tokens",
            sourceNote: "Your GitLab **To-Do list** is this queue. Marking a row done marks it done there too, so it stops arriving.",
            grouping: .init(noun: "project", defaultOn: true)),
        .init(
            id: "trello", displayName: "Trello", systemImage: "rectangle.split.3x1",
            fields: [
                .init(
                    key: "apiKey", label: "API Key", isSecret: false,
                    placeholder: "0123456789abcdef…",
                    help: "Trello treats this one as public."),
                .init(
                    key: "token", label: "Token", isSecret: true,
                    help: ""),
            ],
            setupSteps: [
                "Open **trello.com/apps/admin** and create a Power-Up — Trello now issues keys through one, even for personal use.",
                "In your Power-Up, open the **API Key** tab and generate a key.",
                "Beside it, click **Token**, allow the access it lists, and copy the token from the page it lands on.",
                "Paste both below.",
            ],
            setupURL: "https://trello.com/apps/admin",
            sourceNote: "Your Trello **notifications** are this queue — mentions, cards you're added to, due dates. Marking a row done marks it read there too.",
            grouping: .init(noun: "board", defaultOn: true)),
        .init(
            id: "slack", displayName: "Slack", systemImage: "number",
            fields: [
                .init(
                    key: "userToken", label: "User OAuth Token", isSecret: true,
                    placeholder: "xoxp-…",
                    help: "Not the “xoxe.xoxp-” token on the apps list — that one expires in 12 hours."),
                .init(
                    key: "appToken", label: "App-Level Token (optional)", isSecret: true,
                    placeholder: "xapp-…",
                    help: "Blank still works — you just won't get channel mentions."),
                .init(
                    key: "saveEmoji", label: "Save Emoji", isSecret: false,
                    placeholder: "pushpin",
                    help: "React with it to save a message to the queue."),
                .init(
                    key: "searchTerms", label: "Keyword Watch", isSecret: false,
                    placeholder: "@you, your project, a customer name",
                    help: "Comma-separated. Matches from the last 24 hours, including public channels you're not in. Blank turns it off."),
                .init(
                    key: "mutedChannels", label: "Mute Channels", isSecret: false,
                    placeholder: "#random, #deploys",
                    help: "Comma-separated. Nothing from these reaches the queue. DMs and emoji saves are never muted."),
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
            setupCost: "You'll create a Slack app from our manifest first — five steps, and your workspace admin may need to approve it.",
            grouping: .init(noun: "channel", defaultOn: true)),
        .init(
            id: "sentry", displayName: "Sentry", systemImage: "ladybug",
            fields: [
                .init(
                    key: "org", label: "Organization Slug", isSecret: false,
                    placeholder: "acme",
                    help: "The `sentry.io/organizations/<slug>/` part of your URL."),
                .init(
                    key: "token", label: "User Auth Token", isSecret: true,
                    placeholder: "sntryu_…",
                    help: ""),
                .init(
                    key: "query", label: "Search", isSecret: false,
                    placeholder: SentryConnector.defaultQuery,
                    help: "Sentry search syntax. Blank uses `\(SentryConnector.defaultQuery)` — its own For Review tab."),
                .init(
                    key: "resolveOnDone", label: "Resolve in Sentry when I mark done",
                    isSecret: false,
                    help: "Resolving is team-visible — it closes the issue for everyone. Left off, done here just means “I've seen this”.",
                    isToggle: true, defaultOn: false),
            ],
            setupSteps: [
                "In Sentry, open **Settings → Account → User Auth Tokens**.",
                "Create a token with the **`event:read`** scope (add `event:write` only if you want this app to resolve issues).",
                "Paste it below, along with your organization slug.",
            ],
            setupURL: "https://sentry.io/settings/account/api/auth-tokens/",
            sourceNote: "Sentry's API works on every plan, the free tier included — what you pay for is event quota, not access.",
            grouping: .init(noun: "project", defaultOn: true)),
        .init(
            id: "appleMail", displayName: "Apple Mail", systemImage: "envelope",
            fields: [
                .init(
                    key: "flagged", label: "Flagged messages", isSecret: false,
                    help: "The strongest signal an inbox has, so these arrive high-signal.",
                    isToggle: true, defaultOn: true),
                .init(
                    key: "unread", label: "Unread messages", isSecret: false,
                    help: "Off by default — unread-in-inbox is thousands of messages for most people.",
                    isToggle: true, defaultOn: false),
                .init(
                    key: "mailbox", label: "Mailbox", isSecret: false,
                    placeholder: "INBOX",
                    help: "Blank watches every account. Name one to narrow it."),
            ],
            allowsMultiple: false,
            // No `setupSteps`, for the reason Reminders has none: there is no
            // credential to fetch, so they could only restate the access
            // section rendered directly below them and the cost line above.
            sourceNote: "Covers every account Mail has, **including Gmail** — which is why there's no separate Gmail source.",
            grouping: .init(noun: "sender", defaultOn: true),
            completeVerb: .init(
                button: "Archive", menu: "Archive in Mail",
                help: "Archive it in Mail and mark it read (C)")),
        .init(
            id: "reminders", displayName: "Apple Reminders", systemImage: "checklist",
            fields: [
                .init(
                    key: "dueToday", label: "Due today or overdue", isSecret: false,
                    help: "Anything you're late on, plus anything due before midnight.",
                    isToggle: true, defaultOn: true),
                .init(
                    key: "lists", label: "Lists", isSecret: false,
                    help: "Everything open in the lists you tick."),
                .init(
                    key: "listsIncludeUndated",
                    label: "Include undated reminders from those lists",
                    isSecret: false,
                    help: "A “someday” list is usually long enough to bury your other sources.",
                    isToggle: true, defaultOn: false),
            ],
            allowsMultiple: false,
            // No `setupSteps` on purpose. There is no credential to fetch, so
            // the steps could only restate the permission control that renders
            // directly below them — which is exactly the duplication Brandon
            // called out on 2026-08-26. `credentialSourcesExplainThemselves`
            // only requires steps of sources that ask for a secret.
            grouping: .init(noun: "list", defaultOn: false),
            completeVerb: .init(
                button: "Complete task", menu: "Complete Task",
                help: "Complete it in Reminders (C)")),
        .init(
            id: "todoist", displayName: "Todoist", systemImage: "checkmark.circle",
            fields: [
                .init(
                    key: "token", label: "API Token", isSecret: true,
                    placeholder: "0123456789abcdef…",
                    help: ""),
                .init(
                    key: "dueToday", label: "Due today or overdue", isSecret: false,
                    help: "Anything you're late on, plus anything due before midnight.",
                    isToggle: true, defaultOn: true),
                .init(
                    key: "projects", label: "Projects", isSecret: false,
                    help: "Everything open in the projects you tick."),
                .init(
                    key: "projectsIncludeUndated",
                    label: "Include undated tasks from those projects",
                    isSecret: false,
                    help: "A “someday” project is usually long enough to bury your other sources.",
                    isToggle: true, defaultOn: false),
            ],
            setupSteps: [
                "In Todoist, open Settings → Integrations → **Developer**.",
                "Copy the **API token** shown there.",
                "Paste it below, then pick what this source should watch.",
            ],
            setupURL: "https://app.todoist.com/app/settings/integrations/developer",
            // The one thing `C` does here that the button cannot promise.
            sourceNote: "**C** on a repeating task reschedules it rather than ticking it off — Todoist's own behaviour, and undo can't take it back.",
            grouping: .init(noun: "project", defaultOn: false),
            completeVerb: .init(
                button: "Complete task", menu: "Complete Task",
                help: "Complete it in Todoist (C)")),
        .init(
            id: "asana", displayName: "Asana", systemImage: "circle.hexagongrid",
            fields: [
                .init(
                    key: "token", label: "Personal Access Token", isSecret: true,
                    placeholder: "2/1234567890/…",
                    help: ""),
                .init(
                    key: "dueToday", label: "Due today or overdue", isSecret: false,
                    help: "Assigned to you, and either late or due before midnight.",
                    isToggle: true, defaultOn: true),
                .init(
                    key: "projects", label: "Projects", isSecret: false,
                    help: "Everything open in them, whoever it's assigned to — Asana can't narrow a project to you."),
                .init(
                    key: "projectsIncludeUndated",
                    label: "Include undated tasks from those projects",
                    isSecret: false,
                    help: "A shared project's undated backlog usually buries your other sources.",
                    isToggle: true, defaultOn: false),
            ],
            setupSteps: [
                "Open Asana's **developer console** and, under Personal access tokens, create one.",
                "Copy the token — Asana shows it once.",
                "Paste it below, then pick what this source should watch.",
            ],
            setupURL: "https://app.asana.com/0/developer-console",
            // The one thing Asana's API cannot see.
            sourceNote: "Asana's Inbox isn't in its API, so this is the tasks assigned to you — not your notifications.",
            grouping: .init(noun: "project", defaultOn: false),
            completeVerb: .init(
                button: "Complete task", menu: "Complete Task",
                help: "Complete it in Asana (C)")),
        .init(
            id: "jsonPoller", displayName: "Custom JSON Feed", systemImage: "curlybraces",
            fields: [
                .init(
                    key: "url", label: "Feed URL", isSecret: false,
                    placeholder: "https://…"),
                .init(key: "authHeader", label: "Authorization Header", isSecret: true,
                    help: "Optional; sent verbatim."),
                .init(
                    key: "mapping", label: "Field Mapping", isSecret: false,
                    placeholder: "id=id,title=title,url=url,time=created_at",
                    help: "Maps feed keys to item fields. Add `root=data` when the list is nested."),
            ],
            setupSteps: [
                "Point **Feed URL** at any URL returning a JSON array — or an object holding one, like Stripe's `{\"data\": […]}`.",
                "In **Field Mapping**, name the keys your feed uses: `id=id,title=title,url=link,time=created_at`, plus `root=data` if the list is nested.",
                "`id` and `title` are required; everything else is optional.",
            ],
            setupCost: "A URL that returns JSON, and a one-line field mapping."),
        .init(
            id: "ntfy", displayName: "ntfy", systemImage: "bell.badge",
            fields: [
                .init(
                    key: "server", label: "Server", isSecret: false,
                    placeholder: "https://ntfy.sh",
                    help: "Leave as ntfy.sh, or point at your own instance."),
                .init(
                    key: "topics", label: "Topics", isSecret: false,
                    placeholder: "deploys,alerts",
                    help: "Comma-separated. On an unprotected topic the name is the only thing keeping strangers out."),
                .init(
                    key: "token", label: "Access Token", isSecret: true,
                    placeholder: "tk_…",
                    help: "Optional, for a protected topic. Wins over username and password."),
                .init(
                    key: "username", label: "Username", isSecret: false,
                    placeholder: "phil",
                    help: "Optional — instead of a token."),
                .init(
                    key: "password", label: "Password", isSecret: true),
            ],
            bannersDefaultOn: true,
            setupSteps: [
                "Choose a topic name — on a public server, anyone who guesses it can publish to you, so make it unguessable.",
                "Enter it below, then send yourself one: `curl -d hello ntfy.sh/<topic>`.",
                "Only if your server protects the topic: add a token, or a username and password.",
            ],
            setupURL: "https://ntfy.sh",
            sourceNote: "Priority 4–5 messages arrive high-signal, and a message's `click` link becomes the item's.",
            setupCost: "A topic name. A token or password only if the topic is protected.",
            grouping: .init(noun: "topic", defaultOn: true)),
        .init(
            id: "local", displayName: "Local coding agents", systemImage: "terminal",
            fields: [],
            // One listener per Mac: a second would fight for the port.
            allowsMultiple: false, bannersDefaultOn: true,
            // No `setupSteps`: the agents set themselves up in the section
            // below, and the only other thing to say is the CLI one-liner.
            sourceNote: "Anything can post here — `inchill notify --title \"Build finished\"` from a script or terminal.",
            setupCost: "Nothing to set up — it listens for the inchill CLI and your coding agents' hooks."),
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

extension SourceConfig {
    /// Whether the panel folds this source's rows: the stored choice, else
    /// the kind's default, else off for a kind with nothing to fold by.
    var groupsAutomatically: Bool {
        autoGroups
            ?? ConnectorCatalog.descriptor(for: kind)?.grouping?.defaultOn
            ?? false
    }
}
