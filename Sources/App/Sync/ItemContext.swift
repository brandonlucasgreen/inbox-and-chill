import Foundation

/// Rich context for one queue item, rendered below the item's text when the
/// row is fully expanded (D). Connectors that declare `.providesContext`
/// build one of these in `context(externalID:payload:)`.
///
/// This is a small set of *typed sections* rather than free-form views so the
/// panel renders every source through one `RowContextView` — a connector
/// decides what to say, never how it looks. All fields are optional-ish;
/// `isEmpty` is the "nothing worth showing" answer and the UI renders nothing
/// for it rather than an empty well.
///
/// `Codable` because the eager sources (Linear, Sentry's chips) build their
/// context at poll time and store it in `Item.payload` — `Store.update`
/// refreshes `payload` every poll, so existing rows repair themselves the
/// same way the Slack-save title fix did. Lazy sources (Slack, GitHub) fetch
/// on demand instead and never persist.
struct ItemContext: Codable, Sendable, Equatable {
    /// One small capsule of metadata: an SF Symbol or a colored dot, plus a
    /// few words. Priority, due date, labels, event counts.
    struct Chip: Codable, Sendable, Equatable {
        var systemImage: String?
        /// Label color from the API ("d73a4a"), drawn as a small dot.
        var dotHex: String?
        var text: String
        var tint: Tint = .neutral

        /// Semantic color for the chip's text/icon. A closed set rather than
        /// a hex so every source's "urgent" is the same orange.
        enum Tint: String, Codable, Sendable {
            case neutral, orange, red, green
        }
    }

    /// One message in a conversation around the item — a Slack thread
    /// message, or the GitHub comment that produced the notification.
    struct Message: Codable, Sendable, Equatable {
        var author: String
        var text: String
        /// The message the notification is *about*. The UI highlights it and
        /// fans the surrounding messages out from it, fading with distance.
        var isFocus: Bool = false
    }

    var chips: [Chip] = []
    /// Ordered oldest-first. At most one message should be the focus.
    var messages: [Message] = []
    /// Small uppercase caption above the messages ("Thread · #deploys").
    var messagesLabel: String?
    /// Monospaced lines — stack frames, rendered on a darker well.
    var frames: [String] = []
    var framesLabel: String?
    /// A short prose block, e.g. a Linear project description.
    var blurb: String?
    var blurbLabel: String?
    /// A named partial failure — some sections loaded, one didn't ("Couldn't
    /// fetch the latest event: …"). Rendered quietly with a warning glyph so
    /// degradation is visible without shouting over what did load (rule 5).
    var note: String?
    /// When true and a focus message is present, the row's own body text is
    /// hidden while this context shows: the focus message *is* the body, so
    /// rendering both would print the same text twice. Slack sets this; a
    /// GitHub comment does not (its body line is the repo name, still useful).
    var replacesBody: Bool = false

    var isEmpty: Bool {
        chips.isEmpty && messages.isEmpty && frames.isEmpty && blurb == nil
            && note == nil
    }
}

/// What a context request produced. `unavailable` is the quiet case — the
/// source has nothing to add for this item, and the UI shows nothing.
/// `failed` is rule 5: the reason is named where the user is looking.
enum ContextFetch: Sendable, Equatable {
    case context(ItemContext)
    case unavailable
    case failed(String)
}

/// The expanded row's view of its context request, owned by `AppState` —
/// exactly one row can be fully expanded, so there is exactly one of these.
/// `idle` covers both "no row is expanded" and "this source adds nothing":
/// the row renders no context section either way.
enum RowContextPhase: Sendable, Equatable {
    case idle
    case loading
    case loaded(ItemContext)
    case failed(String)
}
