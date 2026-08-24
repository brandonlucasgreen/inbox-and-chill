import Foundation
import Testing

@testable import InboxAndChill

// MARK: - Linear row text (Sources/App/Connectors/Linear/LinearConnector.swift)

/// The ten `type` values below are the ones actually present in Brandon's
/// Linear inbox, so they double as a regression net for the bug this suite
/// was written for: non-issue notifications rendering as
/// "documentCommentMention: Linear notification".
struct LinearDescribeTests {
    private func node(
        type: String,
        issue: LinearNotificationNode.Issue? = nil,
        document: LinearNotificationNode.TitledEntity? = nil,
        initiative: LinearNotificationNode.NamedEntity? = nil,
        initiativeUpdate: LinearNotificationNode.UpdateEntity? = nil,
        project: LinearNotificationNode.ProjectEntity? = nil,
        projectUpdate: LinearNotificationNode.UpdateEntity? = nil,
        pullRequest: LinearNotificationNode.TitledEntity? = nil,
        customer: LinearNotificationNode.NamedEntity? = nil,
        productAnnouncement: LinearNotificationNode.TitledEntity? = nil,
        comment: LinearNotificationNode.Comment? = nil,
        url: String? = nil,
        subtitle: String? = nil,
        documentId: String? = nil
    ) -> LinearNotificationNode {
        LinearNotificationNode(
            id: "n1", type: type, createdAt: "2026-08-18T09:00:00.000Z",
            actor: .init(displayName: "amaan"),
            url: url, subtitle: subtitle, documentId: documentId,
            issue: issue, comment: comment, document: document,
            initiative: initiative, initiativeUpdate: initiativeUpdate,
            project: project, projectUpdate: projectUpdate,
            pullRequest: pullRequest, customer: customer,
            productAnnouncement: productAnnouncement)
    }

    private let coreIssue = LinearNotificationNode.Issue(
        identifier: "CORE-6872", title: "Google Drive upload takes a long time",
        url: "https://linear.app/buffer/issue/CORE-6872")

    // MARK: Issue notifications

    @Test func issueCommentMentionLeadsWithTheMention() {
        let (title, _, url) = LinearConnector.describe(
            node(type: "issueCommentMention", issue: coreIssue))
        #expect(title == "Mentioned in CORE-6872: Google Drive upload takes a long time")
        #expect(url == "https://linear.app/buffer/issue/CORE-6872")
    }

    @Test func issueMentionAndAssignmentKeepTheirExistingPhrasing() {
        #expect(
            LinearConnector.describe(node(type: "issueMention", issue: coreIssue)).title
                == "Mentioned in CORE-6872: Google Drive upload takes a long time")
        #expect(
            LinearConnector.describe(node(type: "issueAssignedToYou", issue: coreIssue)).title
                == "Assigned: CORE-6872: Google Drive upload takes a long time")
        #expect(
            LinearConnector.describe(node(type: "issueNewComment", issue: coreIssue)).title
                == "New comment on CORE-6872: Google Drive upload takes a long time")
    }

    @Test func issueStatusChangedAndAddedToViewReadAsProse() {
        #expect(
            LinearConnector.describe(node(type: "issueStatusChanged", issue: coreIssue)).title
                == "Status changed: CORE-6872: Google Drive upload takes a long time")
        #expect(
            LinearConnector.describe(node(type: "issueAddedToView", issue: coreIssue)).title
                == "Added to view: CORE-6872: Google Drive upload takes a long time")
    }

    /// The row opens to a paragraph while selected, so the snippet is the
    /// whole comment flattened — not just its opening line, which is what
    /// this asserted while a row was one line tall.
    @Test func commentBodyBecomesTheSnippetAsOneParagraph() {
        let (_, snippet, _) = LinearConnector.describe(
            node(
                type: "issueCommentMention", issue: coreIssue,
                comment: .init(body: "  first line  \n\nsecond line")))
        #expect(snippet == "first line second line")
    }

    @Test func aLongCommentIsCappedRatherThanCarriedWhole() {
        let body = String(repeating: "word ", count: 200)
        let snippet = LinearConnector.snippetText(body)
        #expect((snippet?.count ?? 0) <= LinearConnector.snippetLimit)
        #expect(snippet?.hasSuffix("…") == true)
    }

    @Test func emptyAndWhitespaceOnlyBodiesProduceNoSnippet() {
        #expect(LinearConnector.snippetText(nil) == nil)
        #expect(LinearConnector.snippetText("") == nil)
        #expect(LinearConnector.snippetText("  \n\n  ") == nil)
    }

    // MARK: Document notifications
    //
    // `DocumentNotification` exposes only `documentId`; `fetch()` resolves
    // it into `document` in a second pass. These are the rows that used to
    // render as "documentCommentMention: Linear notification".

    @Test func documentTypesAreNamedFromTheResolvedDocument() {
        let link = "https://linear.app/buffer/document/launch-plan-a1b2#comment-9"
        let (title, _, url) = LinearConnector.describe(
            node(
                type: "documentCommentMention", document: .init(title: "Launch plan"),
                url: link))
        #expect(title == "Mentioned in Launch plan")
        #expect(url == link)

        #expect(
            LinearConnector.describe(
                node(type: "documentNewComment", document: .init(title: "Launch plan"))
            ).title == "New comment on Launch plan")
        #expect(
            LinearConnector.describe(
                node(type: "documentCommentReaction", document: .init(title: "Launch plan"))
            ).title == "Reaction on Launch plan")
    }

    /// Regression: `subtitle` is the comment body, not a name. Feeding it to
    /// the title produced headlines hundreds of characters long.
    @Test func subtitleFeedsTheSnippetAndNeverTheTitle() {
        let body =
            "Simon Heaton mentioned you: Generally aligned here @Mike Eckstein "
            + "that different launches will yield slightly different outcomes."
        let (title, snippet, _) = LinearConnector.describe(
            node(type: "documentCommentMention", subtitle: body))
        #expect(title == "Mentioned you")
        #expect(snippet == body)
    }

    @Test func anUnresolvedDocumentStillGetsItsRealDeepLink() {
        let link = "https://linear.app/buffer/document/launch-plan-a1b2#comment-9"
        let (_, _, url) = LinearConnector.describe(
            node(type: "documentCommentMention", url: link, documentId: "doc-1"))
        #expect(url == link)
    }

    // MARK: Initiative / project / pull request notifications

    @Test func initiativeUpdateMentionNamesTheInitiative() {
        let (title, _, url) = LinearConnector.describe(
            node(
                type: "initiativeUpdateMention",
                initiative: .init(name: "Publishing 2026", url: "https://linear.app/i/pub"),
                initiativeUpdate: .init(url: "https://linear.app/i/pub/update/7")))
        #expect(title == "Mentioned in Publishing 2026")
        // No interface `url` on this node, so it falls through to the
        // update's own link rather than the initiative's.
        #expect(url == "https://linear.app/i/pub/update/7")
    }

    @Test func pullRequestChecksFailedNamesThePullRequest() {
        let (title, _, url) = LinearConnector.describe(
            node(
                type: "pullRequestChecksFailed",
                pullRequest: .init(
                    title: "Bump pnpm to 11.22.0", url: "https://github.com/x/y/pull/12")))
        #expect(title == "Checks failed: Bump pnpm to 11.22.0")
        #expect(url == "https://github.com/x/y/pull/12")
    }

    @Test func customerAndAnnouncementEntitiesAreNamed() {
        #expect(
            LinearConnector.describe(
                node(type: "customerNeedMarkedAsImportant", customer: .init(name: "Acme Co"))
            ).title == "Marked important: Acme Co")
        #expect(
            LinearConnector.describe(
                node(type: "documentMention", productAnnouncement: .init(title: "New inbox"))
            ).title == "Mentioned in New inbox")
    }

    @Test func attachedDocumentOutranksItsContainer() {
        let (title, _, _) = LinearConnector.describe(
            node(
                type: "projectCommentMention",
                document: .init(title: "Spec v2"),
                project: .init(name: "Publishing")))
        #expect(title == "Mentioned in Spec v2")
    }

    // MARK: Unknown and degenerate types

    @Test func unknownTypeDegradesToProseNotARawEnum() {
        // Live in Brandon's inbox, absent from Linear's published enum.
        let title = LinearConnector.describe(
            node(type: "projectUpdateMentionPrompt", project: .init(name: "Publishing"))
        ).title
        #expect(title == "Project update mention prompt — Publishing")
        #expect(!title.contains("projectUpdateMentionPrompt"))
    }

    @Test func brandNewTypeWithNoEntityStillReadsAsProse() {
        #expect(
            LinearConnector.headline(type: "sprintGoalRewritten", entity: nil)
                == "Sprint goal rewritten")
        #expect(
            LinearConnector.headline(type: "sprintGoalRewritten", entity: "Q3")
                == "Sprint goal rewritten — Q3")
    }

    @Test func knownTypeWithNoResolvableEntityUsesStandaloneWording() {
        #expect(LinearConnector.headline(type: "documentCommentMention", entity: nil)
            == "Mentioned you")
        #expect(LinearConnector.headline(type: "issueAssignedToYou", entity: nil)
            == "Assigned to you")
    }

    @Test func emptyTypeNeverProducesAnEmptyTitle() {
        #expect(LinearConnector.headline(type: "", entity: nil) == "Linear notification")
        #expect(LinearConnector.headline(type: "", entity: "Q3") == "Linear notification — Q3")
    }

    @Test func noEntityAndNoInterfaceURLFallsBackToTheInbox() {
        let (_, _, url) = LinearConnector.describe(node(type: "welcomeMessage"))
        #expect(url == "https://linear.app/inbox")
    }

    // MARK: sentenceCase

    @Test func sentenceCaseSplitsOnLowerToUpperBoundariesOnly() {
        #expect(
            LinearConnector.sentenceCase("projectMilestoneThreadResolved")
                == "Project milestone thread resolved")
        #expect(LinearConnector.sentenceCase("issueStatusChangedAll") == "Issue status changed all")
        // An acronym run stays whole instead of shattering into letters.
        #expect(LinearConnector.sentenceCase("issueSLABreached") == "Issue slabreached")
        #expect(LinearConnector.sentenceCase("system") == "System")
    }

    // MARK: Suffix precedence

    @Test func longerSuffixesWinOverShorterOnesTheyEndWith() {
        // `issueThreadResolved` ends with both "ThreadResolved" and
        // "Resolved"; the more specific phrasing has to win.
        #expect(
            LinearConnector.headline(type: "issueThreadResolved", entity: "CORE-1: Fix")
                == "Thread resolved on CORE-1: Fix")
        #expect(
            LinearConnector.headline(type: "customerNeedResolved", entity: "Acme")
                == "Resolved: Acme")
        // `documentUnsubscribed` must not match "Subscribed".
        #expect(
            LinearConnector.headline(type: "documentUnsubscribed", entity: "Plan")
                == "Unsubscribed from Plan")
    }

    // MARK: High signal

    @Test func mentionsAndDirectRequestsAreHighSignal() {
        for type in [
            "issueCommentMention", "documentCommentMention", "initiativeUpdateMention",
            "issueAssignedToYou", "pullRequestReviewRequested", "issueAddedToTriage",
            "issueDue",
        ] {
            #expect(LinearConnector.isHighSignal(type), "\(type) should be high signal")
        }
    }

    @Test func reactionsAndAmbientChangesStayQuiet() {
        for type in [
            "documentCommentReaction", "issueEmojiReaction", "issueStatusChanged",
            "issueAddedToView", "pullRequestChecksFailed", "documentSubscribed",
        ] {
            #expect(!LinearConnector.isHighSignal(type), "\(type) should be low signal")
        }
    }

    @Test func unpublishedMentionVariantsStayHighSignal() {
        // Not in `highSignalTypes`; caught by the residual mention rule.
        #expect(LinearConnector.isHighSignal("projectUpdateMentionPrompt"))
    }

    // MARK: mapItem

    @Test func mapItemCarriesActorTypeAndSignalThrough() {
        let item = LinearConnector.mapItem(
            node(type: "documentCommentMention", document: .init(title: "Launch plan")))
        #expect(item.externalID == "n1")
        #expect(item.kind == "documentCommentMention")
        #expect(item.title == "Mentioned in Launch plan")
        #expect(item.actorName == "amaan")
        #expect(item.highSignal)
    }
}
