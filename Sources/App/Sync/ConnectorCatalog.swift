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
    /// Defaults for new sources of this kind (decision §2.1.4: local
    /// sources banner by default).
    var bannersDefaultOn: Bool = false
    /// Shown in the source editor under the credential fields: why this
    /// provider is paste-a-token rather than OAuth (PLAN §6.9 verdicts).
    var authNote: String = ""
}

enum ConnectorCatalog {
    static let all: [ConnectorKindDescriptor] = [
        .init(
            id: "linear", displayName: "Linear", systemImage: "line.3.horizontal.decrease.circle",
            fields: [
                .init(
                    key: "apiKey", label: "Personal API Key", isSecret: true,
                    placeholder: "lin_api_…",
                    help: "Linear → Settings → API → Personal API keys")
            ]),
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
            authNote: "Why no “Sign in with GitHub”? GitHub's notifications API only accepts classic personal access tokens — it rejects OAuth app tokens and fine-grained PATs outright. The token is stored in your Keychain and never leaves this Mac."),
        .init(
            id: "slack", displayName: "Slack", systemImage: "number",
            fields: [
                .init(
                    key: "userToken", label: "User OAuth Token", isSecret: true,
                    placeholder: "xoxp-…",
                    help: "From your workspace app's OAuth & Permissions page"),
                .init(
                    key: "appToken", label: "App-Level Token (optional)", isSecret: true,
                    placeholder: "xapp-…",
                    help: "Socket Mode token with connections:write. Leave blank and Slack still works — you just won't get channel mentions."),
                .init(
                    key: "saveEmoji", label: "Save Emoji", isSecret: false,
                    placeholder: "pushpin",
                    help: "Reacting with this emoji saves a message to the queue"),
            ],
            authNote: "Why paste tokens? Your workspace app's install page *is* Slack's OAuth flow — it ends by displaying the user token. A native app can't run Slack's OAuth itself: the token exchange requires your client secret (Slack has no PKCE public-client mode), and redirect URLs must be HTTPS, so there's no loopback to come back to. The app-level token never comes from OAuth at all.\n\nOnly the user token is required. Adding the app-level token turns on Socket Mode, which is the only supported way to receive channel mentions — Slack publishes no API for “messages that mention me”, so without it you get DM unreads, emoji saves and read-state auto-clear, but not mentions. Both tokens live in your Keychain and never leave this Mac."),
        .init(
            id: "campsite", displayName: "Campsite", systemImage: "tent",
            fields: [
                .init(
                    key: "baseURL", label: "Base URL", isSecret: false,
                    placeholder: "https://campsite.buffer.com"),
                .init(
                    key: "orgSlug", label: "Organization Slug", isSecret: false,
                    placeholder: "buffer",
                    help: "The org segment in your Campsite URLs"),
                .init(key: "token", label: "Access Token", isSecret: true),
            ]),
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
                    help: "Optional — only for protected topics (`ntfy token add`)"),
            ],
            bannersDefaultOn: true,
            authNote: "No OAuth needed, and none to skip: ntfy has no accounts on unprotected topics — publishing to a topic is the whole API. Priority 4–5 messages arrive as high-signal; `click` becomes the item's link. The token is optional, stored in your Keychain, and never leaves this Mac."),
        .init(
            id: "local", displayName: "Local (Terminal & Claude Code)", systemImage: "terminal",
            fields: [], bannersDefaultOn: true),
    ]

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
