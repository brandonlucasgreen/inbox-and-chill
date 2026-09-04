import Foundation

// Pure keyword-watch helpers for Slack — parsing settings strings, mapping
// `search.messages` matches to items, and naming Slack's rejection codes.
// Split out of SlackConnector.swift so the actor is closer to a single
// concern (the run loop and its caches). Tests import these as
// `SlackConnector.foo` unchanged.

extension SlackConnector {
    /// Slack errors that re-polling will never fix.
    static let permanentSearchFailures: Set<String> = [
        "missing_scope", "not_allowed_token_type", "invalid_auth",
        "account_inactive", "token_revoked",
    ]

    nonisolated static func searchScopeAdvice(code: String) -> String {
        switch code {
        case "missing_scope", "not_allowed_token_type":
            return
                """
                Slack Keyword Watch needs the `search:read` scope, which this token doesn't have (\(code)).                 Add it under OAuth & Permissions, reinstall the app to your workspace, then paste the new                 user token here. Clear the Keyword Watch field to turn the feature off instead.
                """
        default:
            return "Slack rejected the keyword search (\(code)). Re-check the user token."
        }
    }

    /// Why the saved-message lookup was refused, and what to do about it.
    /// Separate from `searchScopeAdvice` because it names a different scope
    /// and a different consequence — saves you make while the app is running
    /// still arrive over Socket Mode; it is the backfill that stops.
    nonisolated static func savedScopeAdvice(code: String) -> String {
        switch code {
        case "missing_scope", "not_allowed_token_type":
            return """
                Slack saved messages need the `reactions:read` scope, which \
                this token doesn't have (\(code)). Add it under OAuth & \
                Permissions, reinstall the app to your workspace, then paste \
                the new user token here. Saves you make from now on still \
                arrive; it's the ones made earlier that can't be read back.
                """
        default:
            return
                "Slack refused the saved-messages lookup (\(code)). Re-check the user token."
        }
    }

    /// Splits the settings string into muted channel names.
    ///
    /// Accepts what a person actually types or pastes: `#random`, `random`,
    /// commas or newlines between them, any casing. A raw channel id
    /// (`C0123ABCD`) is accepted too — it is what you get from Slack's
    /// "Copy link", and the search API hands us ids for free even when it
    /// hands us no name.
    ///
    /// Uncapped, unlike watch terms: this costs no API calls, it is a set
    /// membership test.
    nonisolated static func parseMutedChannels(_ raw: String) -> Set<String> {
        var muted = Set<String>()
        for piece in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            var name = piece.trimmingCharacters(in: .whitespaces)
            while name.hasPrefix("#") { name.removeFirst() }
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            muted.insert(name.lowercased())
        }
        return muted
    }

    /// True when a channel is muted, by either name or id.
    ///
    /// Pure so the rule is testable without a workspace, and deliberately
    /// tolerant: a name is matched case-insensitively with any leading `#`
    /// stripped, because "#Deploys" and "deploys" are the same channel to
    /// everyone except a string comparison.
    nonisolated static func isMuted(
        channelName: String?, channelID: String?, muted: Set<String>
    ) -> Bool {
        guard !muted.isEmpty else { return false }
        for candidate in [channelName, channelID] {
            guard var value = candidate?.trimmingCharacters(in: .whitespaces), !value.isEmpty
            else { continue }
            while value.hasPrefix("#") { value.removeFirst() }
            if muted.contains(value.lowercased()) { return true }
        }
        return false
    }

    /// Splits the settings string into watch terms.
    ///
    /// Commas and newlines both separate, so the field accepts a typed list or
    /// a pasted one. Case-insensitively deduped (Slack search is
    /// case-insensitive, so two spellings would just cost an extra call) and
    /// capped, because every term is one API request per poll.
    nonisolated static func parseSearchTerms(_ raw: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let term = piece.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == maxSearchTerms { break }
        }
        return terms
    }

    /// Builds one `search.messages` query.
    ///
    /// A multi-word term is quoted so it stays a phrase rather than an OR of
    /// its words. `after:` is date-granular in Slack and *exclusive*, so it is
    /// deliberately widened by a day and the precise cutoff enforced against
    /// each match's timestamp in `watchHit`.
    nonisolated static func searchQuery(term: String, after: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let widened = after.addingTimeInterval(-TimeInterval(24 * 60 * 60))
        let parts = calendar.dateComponents([.year, .month, .day], from: widened)
        let stamp = String(
            format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        let needsQuotes = term.contains(" ") && !term.hasPrefix("\"")
        let phrase = needsQuotes ? "\"\(term)\"" : term
        return "\(phrase) after:\(stamp)"
    }

    /// True for Slack ids masquerading as a channel name (`U…`, `D…`, `C…`,
    /// `G…` followed by uppercase alphanumerics), which is what search returns
    /// for direct and group messages.
    nonisolated static func isRawChannelID(_ name: String) -> Bool {
        guard name.count >= 8, let first = name.first, "UDCG".contains(first) else { return false }
        return name.dropFirst().allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// Maps one `search.messages` match to a queue item.
    ///
    /// Returns nil for anything outside the window, authored by you, or
    /// missing the ids a triage verb needs — pure, so the mapping is testable
    /// without a workspace.
    nonisolated static func watchHit(
        from match: SlackJSON, term: String, selfUserID: String, teamID: String = "",
        notBefore: Date
    ) -> (channel: String, ts: String, item: RemoteItem)? {
        guard let ts = match["ts"].nonEmptyString,
            let channel = match["channel"]["id"].nonEmptyString,
            let occurredAt = SlackTS.date(ts), occurredAt >= notBefore
        else { return nil }
        // You writing your own keyword is not news.
        if !selfUserID.isEmpty, match["user"].nonEmptyString == selfUserID { return nil }

        let who =
            match["username"].nonEmptyString
            ?? match["user"].nonEmptyString ?? "Someone"
        // Slack returns a raw id as the "name" for DMs and group DMs, which
        // would render as "#U4NUMLRJQ". Anything that looks like an id gets
        // described instead of printed.
        let rawName = match["channel"]["name"].nonEmptyString
        let channelLabel = rawName.map { Self.isRawChannelID($0) ? "a direct message" : $0 }
            ?? "a channel"
        let permalink = match["permalink"].nonEmptyString
        return (
            channel, ts,
            RemoteItem(
                externalID: "watch-\(channel)-\(ts)",
                kind: "keyword_watch",
                title: "“\(term)” in #\(channelLabel)",
                snippet: truncate(match["text"].nonEmptyString, snippetLimit),
                // Native first: Slack.app can't be handed an https URL, so a
                // permalink would go out to the default browser and bounce.
                url: permalink.flatMap { nativeLink(fromPermalink: $0, teamID: teamID) }
                    ?? permalink,
                actorName: who,
                occurredAt: occurredAt,
                highSignal: true,
                payload: payload(channel: channel, ts: ts, permalink: permalink),
                groupKey: channelGrouping(channel: channel, label: rawName)?.key,
                groupLabel: channelGrouping(channel: channel, label: rawName)?.label)
        )
    }

    /// What a saved row is called. `channelName` falls back to the raw
    /// channel id when `conversations.info` has no `name` — which is every
    /// DM — so the id has to be described rather than printed, exactly as
    /// `watchHit` already does. Pure, so both cases are testable without a
    /// workspace.
    /// The fold a channel message belongs to: the channel id as the key
    /// (stable across renames) and the name as the label. nil for a DM or a
    /// channel whose name never resolved — a header reading `C0AP7Q92ZPB`
    /// is worse than the rows it would hide. A DM is one row per
    /// conversation already, so it never needs one.
    nonisolated static func channelGrouping(
        channel: String, label: String?
    ) -> (key: String, label: String)? {
        guard let label, !label.isEmpty, !isRawChannelID(label) else {
            return nil
        }
        return (channel, "#\(label)")
    }

    nonisolated static func saveTitle(channelLabel: String?) -> String {
        guard let label = channelLabel, !label.isEmpty else {
            return "Saved message"
        }
        if isRawChannelID(label) { return "Saved from a direct message" }
        return "Saved in #\(label)"
    }
}
