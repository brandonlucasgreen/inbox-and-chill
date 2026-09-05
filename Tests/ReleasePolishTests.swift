import AppKit
import Foundation
import Testing

@testable import InboxAndChill

// MARK: - First run (Sources/App/UI/FirstRun.swift)

/// A fresh install used to read "You're all caught up ☺" — finished rather
/// than unstarted. These pin the policy that decides which it is.
@Suite("First run")
struct FirstRunTests {

    /// Nothing is pre-added any more — the local source included — so "no
    /// source yet" means no source of any kind.
    @Test("No source of any kind means no source yet")
    func needsFirstSource() {
        #expect(FirstRun.needsFirstSource(kinds: []))
        #expect(!FirstRun.needsFirstSource(kinds: ["local"]))
        #expect(!FirstRun.needsFirstSource(kinds: ["appleMail"]))
    }

    /// Existence, not enablement: someone who switched everything off on
    /// purpose is not greeted like a stranger. The policy takes kinds only,
    /// so it cannot even see `isEnabled`.
    @Test("The welcome window shows once, and only for an install with no source")
    func welcomeWindowShowsOnce() {
        #expect(FirstRun.shouldShowWelcomeWindow(hasLaunchedBefore: false, needsFirstSource: true))
        #expect(!FirstRun.shouldShowWelcomeWindow(hasLaunchedBefore: true, needsFirstSource: true))
        // An upgrade is not a first run.
        #expect(!FirstRun.shouldShowWelcomeWindow(hasLaunchedBefore: false, needsFirstSource: false))
    }

    /// Brandon: naming Mail and Reminders *"sells short the depth of services
    /// I&C integrates with"*. The roster comes from the catalog, so a new
    /// connector joins the sentence on its own.
    @Test("The welcome names the whole roster and features no source")
    func rosterNamesEverything() {
        let roster = FirstRun.sourceRoster(from: ConnectorCatalog.all)
        for descriptor in ConnectorCatalog.all where !["local", "jsonPoller", "ntfy"].contains(descriptor.id) {
            #expect(roster.contains(descriptor.displayName), "\(descriptor.id)")
        }
        #expect(roster.contains("ntfy"))
        #expect(roster.contains("JSON feed"))
        #expect(roster.contains("coding agents"))
        #expect(FirstRun.addButton == "Add Your First Source")
    }

    /// Asking twice for the same kind must read as two requests, or the
    /// `onChange` observer in `SourcesPane` fires once and never again.
    @Test("Two add requests for the same kind are distinct")
    func addRequestsAreDistinct() {
        let first = AppState.AddSourceRequest(kind: "appleMail")
        let second = AppState.AddSourceRequest(kind: "appleMail")
        #expect(first.kind == second.kind)
        #expect(first != second)
    }
}

// MARK: - Brand (Sources/App/UI/Brand.swift)

/// The bundled typefaces register at launch through `ATSApplicationFontsPath`.
/// This runs inside the app as test host, so if the folder or the plist key
/// is wrong the faces are simply absent — and the welcome would render in
/// SF with nothing failing anywhere else.
@Suite("Brand fonts")
struct BrandFontTests {
    @Test("Syne and Space Grotesk are registered from the bundle")
    func bundledFacesResolve() {
        let available = Set(NSFontManager.shared.availableFonts)
        #expect(Brand.firstAvailable(Brand.displayFaces, in: available) != nil,
            "no Syne instance registered — check Resources/Fonts and ATSApplicationFontsPath")
        #expect(Brand.firstAvailable(Brand.textFaces, in: available) != nil,
            "no Space Grotesk instance registered")
        #expect(NSFont(name: "Syne-SemiBold", size: 12) != nil)
    }

    @Test("A missing face falls back to the next, then to nil")
    func fallbackOrder() {
        #expect(Brand.firstAvailable(["A", "B"], in: ["B"]) == "B")
        #expect(Brand.firstAvailable(["A", "B"], in: ["A", "B"]) == "A")
        #expect(Brand.firstAvailable(["A"], in: []) == nil)
    }

    @Test("The house tagline has one home")
    func taglineIsShared() {
        #expect(Brand.tagline == "Everything waiting on you, in one queue, nice & chilled.")
    }
}

// MARK: - Fake connector (Sources/App/Connectors/FakeConnector.swift)

/// The fake source wrote rows into the live store from a test run on
/// 2026-09-04, because a fresh install has zero sources and the connector
/// registered itself whenever no real one existed. Three gates now.
@Suite("Fake connector gating")
struct FakeConnectorGatingTests {
    @Test("Registers only when asked, only with no real source, never under tests")
    func gates() {
        let on = [FakeConnector.optInKey: "1"]
        #expect(FakeConnector.shouldRegister(configKinds: [], environment: on, runningTests: false))
        #expect(FakeConnector.shouldRegister(configKinds: ["local"], environment: on, runningTests: false))
        // A real source anywhere means no fakes mixed in.
        #expect(!FakeConnector.shouldRegister(configKinds: ["slack"], environment: on, runningTests: false))
        // Not asked for: a fresh Debug install shows the welcome, not fakes.
        #expect(!FakeConnector.shouldRegister(configKinds: [], environment: [:], runningTests: false))
        #expect(!FakeConnector.shouldRegister(configKinds: [], environment: ["INCHILL_NO_FAKE": "1"], runningTests: false))
        // The test host shares the live store; it must never register one.
        #expect(!FakeConnector.shouldRegister(configKinds: [], environment: on, runningTests: true))
    }
}

// MARK: - Setup cost (ConnectorKindDescriptor.setupCostLabel)

@Suite("Setup cost line")
struct SetupCostTests {

    @Test("Every kind says what it will ask for, in one short line")
    func everyKindHasALine() {
        for descriptor in ConnectorCatalog.all {
            let line = descriptor.setupCostLabel
            #expect(!line.isEmpty, "\(descriptor.id)")
            #expect(line.count <= 160, "\(descriptor.id)")
        }
    }

    /// The derivation: a secret field means a token; no secret means nothing.
    @Test("Zero-setup kinds say so; token kinds name the token")
    func derivedLines() {
        #expect(ConnectorCatalog.descriptor(for: "appleMail")?.setupCostLabel.contains("Nothing to set up") == true)
        #expect(ConnectorCatalog.descriptor(for: "reminders")?.setupCostLabel.contains("Nothing to set up") == true)
        #expect(ConnectorCatalog.descriptor(for: "linear")?.setupCostLabel.contains("token") == true)
        #expect(ConnectorCatalog.descriptor(for: "todoist")?.setupCostLabel.contains("Todoist") == true)
    }

    /// Slack is the one a first-time buyer must not pick blind.
    @Test("Slack says an app comes first; the feed and ntfy say what they take")
    func overrides() {
        #expect(ConnectorCatalog.descriptor(for: "slack")?.setupCostLabel.contains("Slack app") == true)
        #expect(ConnectorCatalog.descriptor(for: "slack")?.setupCostLabel.contains("admin") == true)
        #expect(ConnectorCatalog.descriptor(for: "jsonPoller")?.setupCostLabel.contains("URL") == true)
        #expect(ConnectorCatalog.descriptor(for: "ntfy")?.setupCostLabel.contains("topic") == true)
        #expect(ConnectorCatalog.descriptor(for: "github")?.setupCostLabel.contains("classic") == true)
    }
}

// MARK: - Trial nudges (Sources/App/Support/Licensing.swift)

@Suite("Trial nudges")
struct TrialNudgeTests {

    @Test("Three days and one day, once each, smallest first")
    func schedule() {
        #expect(TrialNudge.due(daysLeft: 14, sent: []) == nil)
        #expect(TrialNudge.due(daysLeft: 4, sent: []) == nil)
        #expect(TrialNudge.due(daysLeft: 3, sent: []) == 3)
        #expect(TrialNudge.due(daysLeft: 2, sent: [3]) == nil)
        #expect(TrialNudge.due(daysLeft: 1, sent: [3]) == 1)
        #expect(TrialNudge.due(daysLeft: 0, sent: [3, 1]) == nil)
    }

    /// A trial first evaluated with one day left sends one banner, not two —
    /// the three-day one is marked sent along with it.
    @Test("A late start does not send yesterday's banner as well")
    func lateStartSendsOne() {
        #expect(TrialNudge.due(daysLeft: 1, sent: []) == 1)
        let sent = TrialNudge.markSent(daysLeft: 1, sent: [])
        #expect(sent == [3, 1])
        #expect(TrialNudge.due(daysLeft: 1, sent: sent) == nil)
        #expect(TrialNudge.due(daysLeft: 0, sent: sent) == nil)
    }

    @Test("The banner names the days and the price, and never the word 'expired'")
    func wording() {
        #expect(TrialNudge.title(daysLeft: 3) == "Inbox & Chill trial — 3 days left")
        #expect(TrialNudge.title(daysLeft: 1) == "Inbox & Chill trial — 1 day left")
        #expect(TrialNudge.title(daysLeft: 0).contains("today"))
        #expect(TrialNudge.body.contains(Licensing.price))
        #expect(!TrialNudge.body.lowercased().contains("expired"))
    }
}

// MARK: - Support e-mail (DiagnosticsReport.supportMailURL)

@Suite("Support e-mail")
struct SupportMailTests {

    @Test("The mail link names the address and the subject, and carries no report")
    func mailLink() throws {
        let snapshot = DiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.6.0", buildVersion: "60",
            osVersion: "26.5", architecture: "arm64",
            installPath: "/Applications/Inbox & Chill.app")
        let url = try #require(DiagnosticsReport.supportMailURL(snapshot))
        #expect(url.scheme == "mailto")
        #expect(url.absoluteString.hasPrefix("mailto:\(SupportContact.email)?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "subject" }?.value?.hasPrefix("Inbox & Chill") == true)
        // Mail clients truncate long mailto bodies, so the body is a pointer.
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.contains("clipboard"))
        #expect(body.count < 300)
    }

    @Test("About and Diagnostics share one address")
    func oneAddress() {
        #expect(SupportContact.email.contains("@"))
        #expect(SupportContact.mailtoURL?.scheme == "mailto")
    }
}
