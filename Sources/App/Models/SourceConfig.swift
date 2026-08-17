import Foundation
import SwiftData

/// A configured connection to one service. Secrets never live here — they go
/// in the Keychain keyed by `id`; this stores only non-sensitive settings.
@Model
final class SourceConfig {
    @Attribute(.unique) var id: String
    /// Connector kind: linear, github, slack, campsite, local, jsonPoller, fake.
    var kind: String
    var displayName: String
    var isEnabled: Bool
    var sortOrder: Int
    /// Whether this source's items count toward the badge (count modes).
    var countsTowardBadge: Bool
    /// Whether new items from this source fire banners (silent by default;
    /// local/Claude sources default on — decision §2.1.4).
    var bannersEnabled: Bool
    /// Non-secret connector settings as JSON (e.g. Slack save emoji,
    /// Campsite base URL, JSON poller mapping).
    var settingsJSON: Data?

    init(
        id: String = UUID().uuidString, kind: String, displayName: String,
        sortOrder: Int = 0, countsTowardBadge: Bool = true,
        bannersEnabled: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.isEnabled = true
        self.sortOrder = sortOrder
        self.countsTowardBadge = countsTowardBadge
        self.bannersEnabled = bannersEnabled
    }
}

enum BadgeStyle: String, CaseIterable, Codable, Sendable {
    case highSignalCount  // default
    case totalCount
    case dot
    case none
}
