import Foundation
import SwiftData

/// One thing you are dealing with, wearing several notifications.
///
/// A topic owns exactly two pieces of state: a **name** and an optional
/// **rule** (`terms`). Everything else about it — active, snoozed, done,
/// pinned, high-signal, seen — is derived from its members, so there is no
/// second state machine to keep in sync with the first and every rule the
/// queue already has keeps working unchanged.
///
/// Membership is a plain `Item.topicID` string rather than a SwiftData
/// relationship. Every cross-entity link in this app is already a string id
/// (`sourceID`, `uid`, the Keychain's `<UUID>.<field>`), `Store` fetches by
/// uid, and nothing holds an object graph. A relationship would need an
/// inverse, would put cascade semantics into `purge()` — which today just
/// deletes rows — and would make `reconcile()` fault in Topic objects once
/// per source.
///
/// A topic **outlives its members on purpose**: all four can auto-archive,
/// the topic renders nowhere, and then tomorrow's matching item re-forms it.
/// That only works if the record survives being empty, which is why `purge`
/// takes both age *and* emptiness into account rather than deleting any
/// topic that happens to have nothing in it right now.
@Model
final class Topic {
    @Attribute(.unique) var id: String
    var name: String
    var createdAt: Date
    /// Auto-catch terms. A newly arriving item matching any of these joins,
    /// unless it already belongs to a topic — an explicit member always beats
    /// a rule.
    var terms: [String]

    init(
        id: String = UUID().uuidString, name: String,
        terms: [String] = [], createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.terms = terms
        self.createdAt = createdAt
    }
}

enum TopicPolicy {
    /// Below this, a topic renders as an ordinary row carrying a topic chip
    /// rather than as a disclosure header.
    ///
    /// A triangle you open to find one thing is a lie, and `.remoteTruth`
    /// erodes topics to a single member routinely — three of four members
    /// being cleared by their sources is a normal Tuesday, not an edge case.
    static let minimumVisibleMembers = 2

    /// A topic is purged only when it is both empty and older than the
    /// archive retention. Empty alone is a normal resting state.
    static func purgeCutoff(now: Date = .now) -> Date {
        TriagePolicy.purgeCutoff(now: now)
    }
}
