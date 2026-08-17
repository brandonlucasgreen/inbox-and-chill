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
    }

    var id: String  // kind string used in SourceConfig.kind
    var displayName: String
    var systemImage: String
    var fields: [Field]
    /// Defaults for new sources of this kind (decision §2.1.4: local
    /// sources banner by default).
    var bannersDefaultOn: Bool = false
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
                    help: "Classic PAT with the `notifications` scope. Fine-grained tokens cannot read notifications.")
            ]),
        .init(
            id: "slack", displayName: "Slack", systemImage: "number",
            fields: [
                .init(
                    key: "userToken", label: "User OAuth Token", isSecret: true,
                    placeholder: "xoxp-…",
                    help: "From your workspace app's OAuth & Permissions page"),
                .init(
                    key: "appToken", label: "App-Level Token", isSecret: true,
                    placeholder: "xapp-…",
                    help: "Socket Mode token with connections:write"),
                .init(
                    key: "saveEmoji", label: "Save Emoji", isSecret: false,
                    placeholder: "pushpin",
                    help: "Reacting with this emoji saves a message to the queue"),
            ]),
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
