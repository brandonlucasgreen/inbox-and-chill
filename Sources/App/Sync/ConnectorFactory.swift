import Foundation

/// Builds a connector from a stored config.
enum ConnectorFactory {
    static func make(config: SourceConfig) -> (any Connector)? {
        let settings = config.settings
        switch config.kind {
        case "fake":
            return FakeConnector(sourceID: config.id)
        case "linear":
            return LinearConnector(sourceID: config.id)
        case "github":
            let field = ConnectorCatalog.descriptor(for: "github")?
                .fields.first { $0.key == "participating" }
            return GitHubConnector(
                sourceID: config.id,
                participating: field?.boolValue(in: settings) ?? true)
        case "local":
            return LocalConnector(sourceID: config.id)
        case "ntfy":
            return NtfyConnector(
                sourceID: config.id, server: settings["server"] ?? "",
                topics: settings["topics"] ?? "",
                username: settings["username"] ?? "")
        case "jsonPoller":
            return JSONPollerConnector(
                sourceID: config.id, urlString: settings["url"] ?? "",
                mapping: settings["mapping"] ?? "")
        case "sentry":
            let field = ConnectorCatalog.descriptor(for: "sentry")?
                .fields.first { $0.key == "resolveOnDone" }
            return SentryConnector(
                sourceID: config.id,
                org: settings["org"] ?? "",
                query: settings["query"] ?? "",
                resolveOnDone: field?.boolValue(in: settings) ?? false)
        case "appleMail":
            let fields = ConnectorCatalog.descriptor(for: "appleMail")?.fields ?? []
            func toggle(_ key: String) -> Bool {
                fields.first { $0.key == key }?.boolValue(in: settings) ?? false
            }
            return AppleMailConnector(
                sourceID: config.id,
                scope: .init(
                    flagged: toggle("flagged"), unread: toggle("unread"),
                    mailbox: settings["mailbox"] ?? ""))
        case "slack":
            return SlackConnector(
                sourceID: config.id,
                saveEmoji: settings["saveEmoji"].flatMap {
                    $0.isEmpty ? nil : $0
                } ?? "pushpin",
                searchTerms: settings["searchTerms"] ?? "",
                mutedChannels: settings["mutedChannels"] ?? "")
        default:
            return nil
        }
    }
}
