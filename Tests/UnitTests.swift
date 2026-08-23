import AppKit
import Foundation
import Sparkle
import SwiftData
import Testing
import UserNotifications

@testable import InboxAndChill

// MARK: - Item lifecycle edge cases (Sources/App/Models/Item.swift)

@MainActor
struct ItemLifecycleTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Item.self, SourceConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeItem(
        uid: String = "test:a", snoozedUntil: Date? = nil, doneAt: Date? = nil
    ) throws -> Item {
        let context = try makeContext()
        let item = Item(
            uid: uid, sourceID: "s", sourceKind: "test", kind: "mention",
            title: "T", occurredAt: .now)
        item.snoozedUntil = snoozedUntil
        item.doneAt = doneAt
        context.insert(item)
        return item
    }

    @Test func freshItemIsActiveOnly() throws {
        let item = try makeItem()
        #expect(item.isActive)
        #expect(!item.isDone)
        #expect(!item.isSnoozed)
    }

    @Test func snoozedUntilFutureIsSnoozedNotActive() throws {
        let item = try makeItem(snoozedUntil: .now.addingTimeInterval(3600))
        #expect(item.isSnoozed)
        #expect(!item.isActive)
        #expect(!item.isDone)
    }

    @Test func snoozedUntilPastIsNotSnoozedAndIsActive() throws {
        // A snooze that has already elapsed should behave as if not snoozed
        // at all — it's just an active item again.
        let item = try makeItem(snoozedUntil: .now.addingTimeInterval(-3600))
        #expect(!item.isSnoozed)
        #expect(item.isActive)
        #expect(!item.isDone)
    }

    @Test func doneWithFutureSnoozeIsDoneNotSnoozedNotActive() throws {
        // done+snoozed combination: doneAt wins outright — isSnoozed's own
        // `doneAt == nil` guard must suppress it even though snoozedUntil is
        // still in the future.
        let item = try makeItem(
            snoozedUntil: .now.addingTimeInterval(3600), doneAt: .now)
        #expect(item.isDone)
        #expect(!item.isSnoozed)
        #expect(!item.isActive)
    }

    @Test func doneWithPastSnoozeIsDoneOnly() throws {
        let item = try makeItem(
            snoozedUntil: .now.addingTimeInterval(-3600), doneAt: .now)
        #expect(item.isDone)
        #expect(!item.isSnoozed)
        #expect(!item.isActive)
    }

    @Test func pinnedFlagIsIndependentOfLifecycle() throws {
        let item = try makeItem()
        #expect(!item.isPinned)
        item.pinnedAt = .now
        #expect(item.isPinned)
        // Pinning alone doesn't change active/done/snoozed state.
        #expect(item.isActive)
    }

    @Test func urlStringRoundTrips() throws {
        let item = try makeItem()
        #expect(item.url == nil)
        item.urlString = "https://example.com/x"
        #expect(item.url == URL(string: "https://example.com/x"))
    }
}

// MARK: - SourceConfig.settings encode/decode round-trip
// (Sources/App/Sync/ConnectorCatalog.swift)

struct SourceConfigSettingsTests {
    @Test func defaultSettingsAreEmpty() {
        let config = SourceConfig(kind: "jsonPoller", displayName: "Feed")
        #expect(config.settings.isEmpty)
    }

    @Test func settingsRoundTripPreservesAllKeys() {
        let config = SourceConfig(kind: "jsonPoller", displayName: "Feed")
        let values = [
            "url": "https://example.com/feed.json",
            "mapping": "id=id,title=title,url=url,time=created_at",
            "authHeader": "Bearer abc123",
        ]
        config.settings = values
        #expect(config.settings == values)
    }

    @Test func settingsOverwriteReplacesPreviousValue() {
        let config = SourceConfig(kind: "slack", displayName: "Slack")
        config.settings = ["saveEmoji": "pushpin"]
        #expect(config.settings["saveEmoji"] == "pushpin")

        config.settings = ["saveEmoji": "star"]
        #expect(config.settings == ["saveEmoji": "star"])
    }

    @Test func settingEmptyDictionaryRoundTrips() {
        let config = SourceConfig(kind: "ntfy", displayName: "ntfy")
        config.settings = ["a": "b"]
        config.settings = [:]
        #expect(config.settings.isEmpty)
    }

    @Test func settingsSurvivesRawJSONDataRoundTrip() throws {
        // settingsJSON is what's actually persisted by SwiftData; make sure
        // the raw Data survives an encode/decode cycle outside the model too.
        let config = SourceConfig(kind: "github", displayName: "GitHub")
        config.settings = ["pat": "ghp_xxx"]
        let raw = try #require(config.settingsJSON)
        let decoded = try JSONDecoder().decode([String: String].self, from: raw)
        #expect(decoded == ["pat": "ghp_xxx"])
    }
}

// MARK: - SnoozePreset date math (Sources/App/UI/SnoozeMenu.swift)
//
// `date(from:calendar:)` takes the reference date and calendar as
// parameters, so exact expectations are possible with a fixed, UTC
// calendar — no dependency on the machine's current time or time zone.
// Reference: 2026-08-17 is a Monday.

struct SnoozePresetTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0)
        -> Date
    {
        var components = DateComponents()
        components.year = y
        components.month = m
        components.day = d
        components.hour = h
        components.minute = min
        components.second = 0
        return utcCalendar.date(from: components)!
    }

    @Test func laterTodayIsExactlyThreeHoursLater() {
        let now = date(2026, 8, 17, 10, 0)
        let result = SnoozePreset.laterToday.date(from: now, calendar: utcCalendar)
        #expect(result == now.addingTimeInterval(3 * 3600))
    }

    @Test func thisEveningBeforeSixPMResolvesToSixPMSameDay() {
        let now = date(2026, 8, 17, 10, 0)
        let result = SnoozePreset.thisEvening.date(from: now, calendar: utcCalendar)
        #expect(result == date(2026, 8, 17, 18, 0))
    }

    @Test func thisEveningAfterSixPMFallsBackToPlusFourHours() {
        let now = date(2026, 8, 17, 19, 0)
        let result = SnoozePreset.thisEvening.date(from: now, calendar: utcCalendar)
        #expect(result == now.addingTimeInterval(4 * 3600))
    }

    @Test func thisEveningExactlyAtSixPMFallsBackToPlusFourHours() {
        // `evening > now` is a strict inequality, so being exactly at 6pm
        // must take the fallback branch, not "6pm today" (which would be
        // now itself, in the past-or-equal sense the code guards against).
        let now = date(2026, 8, 17, 18, 0)
        let result = SnoozePreset.thisEvening.date(from: now, calendar: utcCalendar)
        #expect(result == now.addingTimeInterval(4 * 3600))
    }

    @Test func tomorrowMorningIsNineAMNextDay() {
        let now = date(2026, 8, 17, 10, 0)
        let result = SnoozePreset.tomorrowMorning.date(from: now, calendar: utcCalendar)
        #expect(result == date(2026, 8, 18, 9, 0))
    }

    @Test func tomorrowMorningLateAtNightStillRollsToNextDayNineAM() {
        let now = date(2026, 8, 17, 23, 30)
        let result = SnoozePreset.tomorrowMorning.date(from: now, calendar: utcCalendar)
        #expect(result == date(2026, 8, 18, 9, 0))
    }

    @Test func nextMondayFromMondayMorningSkipsTodayEntirely() {
        // now is itself a Monday, before 9am — the algorithm still jumps to
        // *next* Monday, not "later today".
        let now = date(2026, 8, 17, 5, 0)
        let result = SnoozePreset.nextMonday.date(from: now, calendar: utcCalendar)
        #expect(result == date(2026, 8, 24, 9, 0))
    }

    @Test func nextMondayFromMondayAfternoonGoesToFollowingMonday() {
        let now = date(2026, 8, 17, 15, 0)
        let result = SnoozePreset.nextMonday.date(from: now, calendar: utcCalendar)
        #expect(result == date(2026, 8, 24, 9, 0))
    }

    @Test func nextMondayFromSundayResolvesToImmediatelyFollowingMonday() {
        let now = date(2026, 8, 16, 10, 0)  // Sunday
        let result = SnoozePreset.nextMonday.date(from: now, calendar: utcCalendar)
        #expect(result == date(2026, 8, 17, 9, 0))
    }

    @Test func nextMondayIsAlwaysAMondayAtNineAMStrictlyInTheFuture() {
        // Invariant sweep across every weekday, independent of the exact
        // "which Monday" logic covered above.
        for dayOffset in 0..<7 {
            let now = utcCalendar.date(
                byAdding: .day, value: dayOffset, to: date(2026, 8, 16, 12, 0))!
            let result = SnoozePreset.nextMonday.date(from: now, calendar: utcCalendar)
            #expect(result > now)
            #expect(utcCalendar.component(.weekday, from: result) == 2)
            #expect(utcCalendar.component(.hour, from: result) == 9)
            #expect(utcCalendar.component(.minute, from: result) == 0)
        }
    }

    @Test func allPresetsResolveStrictlyAfterNowWithDefaultClock() {
        // Exercises the `now: Date = .now` default-argument overload without
        // asserting exact wall-clock values (those are covered above with a
        // fixed reference date).
        let before = Date.now
        for preset in SnoozePreset.allCases {
            #expect(preset.date() > before)
        }
    }

    @Test func tomorrowMorningWithDefaultClockIsNineAM() {
        let result = SnoozePreset.tomorrowMorning.date()
        #expect(Calendar.current.component(.hour, from: result) == 9)
        #expect(Calendar.current.component(.minute, from: result) == 0)
    }
}

// MARK: - Footer hints (Sources/App/UI/PanelHint.swift)

/// The footer is icon-only and `.help()` tooltips never render inside a
/// `MenuBarExtra(.window)` panel, so these strings are the only explanation
/// the footer has. A wrong one is invisible until someone hovers.
struct PanelHintTests {
    @Test("A hint with a shortcut reads as one help line")
    func helpTextWithShortcut() {
        #expect(
            PanelHint.helpText("Refresh all sources", shortcut: "⌘R")
                == "Refresh all sources (⌘R)")
    }

    @Test("A hint without a shortcut gains no empty parentheses")
    func helpTextWithoutShortcut() {
        #expect(PanelHint.helpText("Slack — connecting…", shortcut: nil)
            == "Slack — connecting…")
        #expect(PanelHint.helpText("Settings", shortcut: "") == "Settings")
    }

    @Test("The bubble text and the help text stay in sync")
    func helpTextMatchesInstance() {
        let hint = PanelHint(text: "Quit Inbox & Chill", shortcut: "⌘Q")
        #expect(hint.helpText == "Quit Inbox & Chill (⌘Q)")
    }
}

// MARK: - Sync dot descriptions (Sources/App/UI/PanelSupport.swift)

/// 7pt of colour is the whole message a status dot carries; `describe` is the
/// only place the app says *why* one went red.
struct SourceStatusDotTests {
    @Test("A synced source names itself and how stale it is")
    func describesOK() {
        let now = Date()
        let synced = now.addingTimeInterval(-5 * 60)
        #expect(
            SourceStatusDot.describe(
                name: "Linear", status: .ok(synced), now: now)
                == "Linear — synced 5m ago")
    }

    @Test("Every status case says the source name and a reason")
    func describesEveryCase() {
        for status: ConnectorStatus? in [
            .ok(.now), .error("invalid_auth"), .connecting, nil,
        ] {
            let text = SourceStatusDot.describe(name: "Slack", status: status)
            #expect(text.hasPrefix("Slack — "))
            #expect(text.count > "Slack — ".count)
        }
    }

    @Test("A never-synced dot doesn't read as an error")
    func describesUnsynced() {
        #expect(
            SourceStatusDot.describe(name: "GitHub", status: nil)
                == "GitHub — not synced yet")
        #expect(
            SourceStatusDot.describe(name: "GitHub", status: .connecting)
                == "GitHub — connecting…")
    }

    @Test("A long error is clamped so the one-line bubble still fits")
    func clampsLongError() {
        let long = String(repeating: "scope_missing ", count: 12)
        let text = SourceStatusDot.describe(name: "Slack", status: .error(long))
        #expect(text.hasSuffix("…"))
        #expect(text.count < 70)
        #expect(text.hasPrefix("Slack — error: scope_missing"))
    }

    @Test("A short error is passed through whole")
    func keepsShortError() {
        #expect(
            SourceStatusDot.describe(name: "ntfy", status: .error("HTTP 401"))
                == "ntfy — error: HTTP 401")
    }
}

// MARK: - Queue motion (Sources/App/UI/PanelSupport.swift)

/// The queue's motion is shared between the panel list, the scroll that
/// follows the selection, and the main window's table. The reduce-motion
/// contract is the part worth pinning: it is easy to add a new animated
/// surface and forget that some people have asked the system for stillness.
struct PanelMotionTests {
    @Test("Reduce Motion yields no animation at all, not a faster one")
    func reduceMotionIsNil() {
        #expect(PanelMotion.queue(reduceMotion: true) == nil)
    }

    @Test("Otherwise the queue animates")
    func motionOtherwisePresent() {
        #expect(PanelMotion.queue(reduceMotion: false) != nil)
    }
}

// MARK: - Refresh phrasing (Sources/App/UI/PanelSupport.swift)

/// `PanelFormat.relative` is written for row timestamps, where "now" stands
/// alone. The empty-queue footer slots it into a sentence, which is how
/// "Last refreshed now ago" reached a screenshot — so the phrase is composed
/// once, and these pin the two ends of it.
struct PanelRefreshPhraseTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("A just-completed refresh reads as a sentence, not \"now ago\"")
    func aFreshRefreshReadsAsASentence() {
        #expect(PanelFormat.refreshed(now, now: now) == "Last refreshed just now")
        #expect(
            PanelFormat.refreshed(now.addingTimeInterval(-59), now: now)
                == "Last refreshed just now")
    }

    /// A clock that puts the last refresh slightly in the future would
    /// otherwise render "Last refreshed soon ago".
    @Test("A future timestamp never produces \"soon ago\"")
    func aFutureRefreshDoesNotSaySoonAgo() {
        let phrase = PanelFormat.refreshed(now.addingTimeInterval(30), now: now)
        #expect(phrase == "Last refreshed just now")
        #expect(!phrase.contains("ago"))
    }

    @Test("Past the minute it goes back to the compact form")
    func olderRefreshesKeepTheCompactForm() {
        #expect(
            PanelFormat.refreshed(now.addingTimeInterval(-240), now: now)
                == "Last refreshed 4m ago")
        #expect(
            PanelFormat.refreshed(now.addingTimeInterval(-7200), now: now)
                == "Last refreshed 2h ago")
    }
}

// MARK: - Menu bar badge (Sources/App/Models/MenuBarBadge.swift)

/// Two independent counters, rendered as `total • high-signal`.
///
/// High signal is a subset of the total, which is what makes dropping a zero
/// counter safe: a zero total implies a zero high signal, so there is no state
/// where trimming hides a non-empty queue.
struct MenuBarBadgeTests {
    @Test("Both counters on read as total then high-signal")
    func bothCounters() {
        #expect(MenuBarBadge.default.text(total: 6, highSignal: 2) == "6 • 2")
    }

    @Test("A zero high-signal count is dropped rather than printed")
    func zeroHighSignalIsTrimmed() {
        // "6 • 0" is noise; the six are still right there in the panel.
        #expect(MenuBarBadge.default.text(total: 6, highSignal: 0) == "6")
    }

    @Test("Each counter can be switched off independently")
    func eitherCounterAlone() {
        let totalOnly = MenuBarBadge(showsTotal: true, showsHighSignal: false)
        let signalOnly = MenuBarBadge(showsTotal: false, showsHighSignal: true)
        #expect(totalOnly.text(total: 6, highSignal: 2) == "6")
        #expect(signalOnly.text(total: 6, highSignal: 2) == "2")
    }

    @Test("An empty queue leaves the icon bare, whatever is switched on")
    func emptyQueueShowsNothing() {
        #expect(MenuBarBadge.default.text(total: 0, highSignal: 0) == nil)
        #expect(
            MenuBarBadge(showsTotal: true, showsHighSignal: false)
                .text(total: 0, highSignal: 0) == nil)
    }

    @Test("Both switched off shows nothing even with a full queue")
    func bothOffShowsNothing() {
        let off = MenuBarBadge(showsTotal: false, showsHighSignal: false)
        #expect(off.text(total: 6, highSignal: 2) == nil)
    }
}

// MARK: - Panel keyboard navigation (Sources/App/UI/PanelKeyInput.swift)

/// The ↑/↓ arithmetic, and the key mapping that feeds it.
///
/// Both used to be private to `PanelView`, which is how "arrows don't move the
/// selection" survived a round of fixes with nothing to catch it. The bug was
/// never in this arithmetic — the keys weren't arriving — but the arithmetic
/// was equally unprovable, so it is pinned here now.
struct PanelSelectionTests {
    private let uids = ["a", "b", "c"]

    @Test("Down steps forward, up steps back")
    func stepsOneRow() {
        #expect(PanelSelection.next(from: "a", in: uids, by: 1) == "b")
        #expect(PanelSelection.next(from: "b", in: uids, by: -1) == "a")
    }

    @Test("Both ends clamp rather than wrapping")
    func clampsAtTheEnds() {
        // Holding ↓ should park on the last row, not teleport to the top.
        #expect(PanelSelection.next(from: "c", in: uids, by: 1) == "c")
        #expect(PanelSelection.next(from: "a", in: uids, by: -1) == "a")
    }

    @Test("With nothing selected, each arrow enters from the end it travels towards")
    func entersFromTheNearEnd() {
        #expect(PanelSelection.next(from: nil, in: uids, by: 1) == "a")
        #expect(PanelSelection.next(from: nil, in: uids, by: -1) == "c")
    }

    @Test("A selection that has been filtered away re-enters cleanly")
    func staleSelectionRecovers() {
        // "z" is gone from the visible list — stepping must not strand the user.
        #expect(PanelSelection.next(from: "z", in: uids, by: 1) == "a")
        #expect(PanelSelection.next(from: "z", in: uids, by: -1) == "c")
    }

    @Test("An empty queue yields nothing, leaving the selection untouched")
    func emptyQueueYieldsNil() {
        #expect(PanelSelection.next(from: nil, in: [], by: 1) == nil)
        #expect(PanelSelection.next(from: "a", in: [], by: -1) == nil)
    }
}

/// Key *codes*, not characters. `charactersIgnoringModifiers` reports arrows as
/// private-use scalars that shift with keyboard layout, so the mapping is
/// pinned to the virtual key codes instead.
struct PanelKeyInputTests {
    private func event(keyCode: UInt16, characters: String = "") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: keyCode)!
    }

    @Test("The four arrows map to the four directions")
    func arrowsMap() {
        #expect(PanelKeyInput(event(keyCode: 126)) == .up)
        #expect(PanelKeyInput(event(keyCode: 125)) == .down)
        #expect(PanelKeyInput(event(keyCode: 123)) == .left)
        #expect(PanelKeyInput(event(keyCode: 124)) == .right)
    }

    @Test("Return, keypad enter, escape and delete are named, not typed")
    func namedKeysMap() {
        #expect(PanelKeyInput(event(keyCode: 36)) == .enter)
        #expect(PanelKeyInput(event(keyCode: 76)) == .enter)
        #expect(PanelKeyInput(event(keyCode: 53)) == .escape)
        #expect(PanelKeyInput(event(keyCode: 51)) == .backspace)
    }

    @Test("Anything else arrives as the character it is")
    func charactersPassThrough() {
        #expect(PanelKeyInput(event(keyCode: 14, characters: "e")) == .character("e"))
        #expect(PanelKeyInput(event(keyCode: 1, characters: "s")) == .character("s"))
    }

    @Test("A press carrying no characters is not an input")
    func emptyPressIsIgnored() {
        // Modifier-only presses land here; treating them as input would let a
        // bare ⌘ press extend the type-to-filter string.
        #expect(PanelKeyInput(event(keyCode: 200)) == nil)
    }
}

// MARK: - Panel layout (Sources/App/UI/PanelQueue.swift)

/// The panel's sections, order and filter rules, derived in one pass.
///
/// These used to be a dozen chained computed properties on the view, each
/// re-running on every read — including `index`, which was read *inside* the
/// row loop and walked every item in the store to answer one lookup. Pulling
/// them into a value is what made the panel linear instead of quadratic, and
/// this suite is what says the behaviour came through the move unchanged.
struct PanelQueueTests {
    private func item(
        _ uid: String, source: String = "a", title: String = "T",
        snippet: String? = nil, actor: String? = nil, minutesAgo: Int = 0,
        pinned: Bool = false, snoozedForHours: Int? = nil
    ) -> Item {
        let item = Item(
            uid: uid, sourceID: source, sourceKind: "test", kind: "mention",
            title: title, snippet: snippet, actorName: actor,
            occurredAt: Date(timeIntervalSinceNow: TimeInterval(-60 * minutesAgo)))
        if pinned { item.pinnedAt = .now }
        if let hours = snoozedForHours {
            item.snoozedUntil = Date(timeIntervalSinceNow: TimeInterval(3600 * hours))
        }
        return item
    }

    private let configs = [
        SourceConfig(id: "a", kind: "test", displayName: "Alpha", sortOrder: 0),
        SourceConfig(id: "b", kind: "test", displayName: "Beta", sortOrder: 1),
    ]

    private func layout(
        _ items: [Item], filter: String? = nil, text: String = "",
        showSnoozed: Bool = false
    ) -> PanelQueue {
        PanelQueue(
            queued: items, configs: configs, sourceFilter: filter,
            filterText: text, showSnoozed: showSnoozed)
    }

    @Test("Pinned rows leave their source group rather than appearing twice")
    func pinnedIsExclusive() {
        let queue = layout([item("1", pinned: true), item("2")])
        #expect(queue.pinned.map(\.uid) == ["1"])
        #expect(queue.groups.flatMap { $0.items.map(\.uid) } == ["2"])
    }

    @Test("Snoozed rows are their own section, and pinned outranks snoozed")
    func snoozedIsExclusiveAndPinnedWins() {
        let queue = layout([
            item("1", snoozedForHours: 3),
            item("2", pinned: true, snoozedForHours: 3),
        ])
        #expect(queue.snoozed.map(\.uid) == ["1"])
        #expect(queue.pinned.map(\.uid) == ["2"])
        #expect(queue.groups.isEmpty)
    }

    @Test("Groups follow configured source order, not item order")
    func groupsFollowSourceOrder() {
        let queue = layout([item("1", source: "b"), item("2", source: "a")])
        #expect(queue.groups.map(\.source.id) == ["a", "b"])
    }

    @Test("Traversal order is pinned, then groups, then snoozed when shown")
    func visibleOrderMatchesTheScreen() {
        let items = [
            item("p", pinned: true), item("a1"), item("b1", source: "b"),
            item("s", snoozedForHours: 2),
        ]
        #expect(layout(items).visibleUIDs == ["p", "a1", "b1"])
        #expect(
            layout(items, showSnoozed: true).visibleUIDs
                == ["p", "a1", "b1", "s"])
    }

    @Test("A collapsed Snoozed section is skipped by the keyboard")
    func collapsedSnoozedIsNotTraversable() {
        // Otherwise ↓ would move the selection onto a row nobody can see.
        let queue = layout([item("s", snoozedForHours: 2)])
        #expect(queue.snoozed.count == 1)
        #expect(queue.visibleUIDs.isEmpty)
        #expect(!queue.isEmpty)
    }

    @Test("The text filter reads title, snippet, person and source name")
    func textFilterFields() {
        let items = [
            item("1", title: "Deploy failed"),
            item("2", title: "T", snippet: "the roadmap doc"),
            item("3", title: "T", actor: "Amaan"),
            item("4", source: "b", title: "T"),
        ]
        #expect(layout(items, text: "deploy").matchCount == 1)
        #expect(layout(items, text: "ROADMAP").matchCount == 1)
        #expect(layout(items, text: "amaan").matchCount == 1)
        #expect(layout(items, text: "beta").matchCount == 1)
        #expect(layout(items, text: "  ").matchCount == 4)
    }

    @Test("Chip counts describe the text filter, before the source scope")
    func chipCountsIgnoreTheSourceScope() {
        // Otherwise picking a chip would zero every other chip's count and
        // there would be no way to see what switching to it would show.
        let items = [item("1"), item("2"), item("3", source: "b")]
        let queue = layout(items, filter: "a")
        #expect(queue.chipCounts == ["a": 2, "b": 1])
        #expect(queue.matchCount == 3)
        #expect(queue.groups.map(\.source.id) == ["a"])
    }

    @Test("The active filter keeps its chip after its last item leaves")
    func filteredSourceKeepsItsChip() {
        // Without this the scope is stuck: the chip you would click to get
        // back to "All" isn't on screen.
        let queue = layout([item("1", source: "a")], filter: "b")
        #expect(queue.chips.map(\.id) == ["a", "b"])
        #expect(queue.isEmpty)
    }

    @Test("An unconfigured source still gets a named group")
    func unknownSourceFallsBack() {
        let queue = layout([item("1", source: "gone")])
        #expect(queue.groups.count == 1)
        #expect(!queue.groups[0].source.name.isEmpty)
    }
}

// MARK: - Claude Code session jump (Sources/App/Connectors/Local/ClaudeSessionTarget.swift)

/// A "Claude needs your input" item used to open the project folder — the one
/// place the session isn't. These pin the rules that decide where it goes
/// instead, all of which have to hold without a terminal, a desktop app, or
/// an AppleEvent in sight.
struct ClaudeSessionTargetTests {
    private func origin(
        host: String? = nil, tty: String? = nil, bundleID: String? = nil
    ) -> LocalListener.SessionOrigin {
        LocalListener.SessionOrigin(
            host: host, entrypoint: nil, termProgram: nil, bundleID: bundleID, tty: tty)
    }

    /// A desktop session runs its own shell, so it can offer both. The
    /// session lives in the app, not in that shell.
    @Test("The desktop session id wins over a tty")
    func desktopIDBeatsTTY() {
        let target = ClaudeSessionTarget.target(
            origin: origin(host: "local_79769598-7df4-47d5-af05-a28cb12ff1c0", tty: "/dev/ttys004"))
        #expect(target == .desktopSession(id: "local_79769598-7df4-47d5-af05-a28cb12ff1c0"))
    }

    @Test("A terminal session is addressed by its tty")
    func terminalSessionUsesTTY() {
        let target = ClaudeSessionTarget.target(
            origin: origin(tty: "/dev/ttys004", bundleID: "com.apple.Terminal"))
        #expect(target == .terminalTab(bundleID: "com.apple.Terminal", tty: "/dev/ttys004"))
    }

    /// Every other connector puts its own thing in `payload`; none of it
    /// decodes to an origin, and none of it may send ⏎ somewhere strange.
    @Test("An empty, absent or foreign payload falls back to the folder")
    func unknownPayloadsFallBackToTheFolder() {
        #expect(ClaudeSessionTarget.target(payload: nil) == .folder)
        #expect(ClaudeSessionTarget.target(payload: Data("{\"permalink\":\"x\"}".utf8)) == .folder)
        #expect(ClaudeSessionTarget.target(origin: LocalListener.SessionOrigin()) == .folder)
    }

    @Test("Session ids are validated before they reach a URL")
    func sessionIDsAreValidated() {
        #expect(
            ClaudeSessionTarget.isValidSessionID("local_79769598-7df4-47d5-af05-a28cb12ff1c0"))
        #expect(ClaudeSessionTarget.isValidSessionID("79769598-7df4-47d5-af05-a28cb12ff1c0"))
        #expect(!ClaudeSessionTarget.isValidSessionID("local_../../etc"))
        #expect(!ClaudeSessionTarget.isValidSessionID(""))
        #expect(
            ClaudeSessionTarget.desktopURL(sessionID: "local_79769598-7df4-47d5-af05-a28cb12ff1c0")?
                .absoluteString
                == "claude://local_sessions/local_79769598-7df4-47d5-af05-a28cb12ff1c0")
        #expect(ClaudeSessionTarget.desktopURL(sessionID: "nonsense") == nil)
    }

    /// The tty is interpolated into an AppleScript string literal, so the
    /// allowlist is the only thing between a posted `origin` and arbitrary
    /// script. A hook is local, but `/notify` is an HTTP endpoint.
    @Test("A tty that could break out of the script is refused outright")
    func ttyValidationBlocksScriptInjection() {
        #expect(ClaudeSessionTarget.isValidTTY("/dev/ttys004"))
        #expect(!ClaudeSessionTarget.isValidTTY("/dev/ttys004\" & (do shell script \"id\") & \""))
        #expect(!ClaudeSessionTarget.isValidTTY("/etc/passwd"))
        // The generic controlling-terminal device: every process has one and
        // it matches no tab, so treating it as an address is worse than
        // having none.
        #expect(!ClaudeSessionTarget.isValidTTY("/dev/tty"))
        #expect(!ClaudeSessionTarget.isValidTTY(""))
        #expect(
            ClaudeSessionTarget.focusScript(
                bundleID: "com.apple.Terminal", tty: "/dev/ttys004\"; beep") == nil)
    }

    @Test("Only terminals with a scriptable tab model get a script")
    func onlyScriptableTerminalsGetAScript() {
        let terminal = ClaudeSessionTarget.focusScript(
            bundleID: "com.apple.Terminal", tty: "/dev/ttys004")
        #expect(terminal?.contains("tty of t is \"/dev/ttys004\"") == true)
        let iterm = ClaudeSessionTarget.focusScript(
            bundleID: "com.googlecode.iterm2", tty: "/dev/ttys004")
        #expect(iterm?.contains("iTerm2") == true)
        // Ghostty, WezTerm, kitty…: fronted, never scripted.
        #expect(
            ClaudeSessionTarget.focusScript(bundleID: "com.mitchellh.ghostty", tty: "/dev/ttys004")
                == nil)
        #expect(ClaudeSessionTarget.focusScript(bundleID: nil, tty: "/dev/ttys004") == nil)
    }

    /// A denied AppleEvent looks exactly like a session that closed, which is
    /// this project's recurring bug class. It has to name the fix.
    @Test("A refused AppleEvent explains itself and names the fix")
    func aRefusedAppleEventNamesTheFix() {
        let denied = ClaudeSessionTarget.explain(appleScriptError: -1743, terminal: "Terminal")
        #expect(denied.contains("Automation"))
        #expect(denied.contains("Terminal"))
        let odd = ClaudeSessionTarget.explain(appleScriptError: -42, terminal: "Terminal")
        #expect(odd.contains("-42"))
    }
}

// MARK: - Keychain write failures (Sources/App/Support/Keychain.swift)


// MARK: - Sentry

@Suite("Sentry timestamp parsing")
struct SentryTimestampTests {
    /// The bug this connector exists to avoid: `ISO8601DateFormatter`'s two
    /// option sets are mutually exclusive, so a single formatter silently
    /// fails on half of all real timestamps.
    @Test("Both fractional and whole-second timestamps parse")
    func bothShapesParse() {
        #expect(SentryConnector.parseTimestamp("2026-08-19T12:34:56.789Z") != nil)
        #expect(SentryConnector.parseTimestamp("2026-08-19T12:34:56Z") != nil)
        #expect(SentryConnector.parseTimestamp("2026-08-19T12:34:56.789000Z") != nil)
    }

    @Test("The two shapes agree on the instant, to the second")
    func shapesAgree() throws {
        let withFraction = try #require(
            SentryConnector.parseTimestamp("2026-08-19T12:34:56.000Z"))
        let without = try #require(
            SentryConnector.parseTimestamp("2026-08-19T12:34:56Z"))
        #expect(abs(withFraction.timeIntervalSince(without)) < 0.001)
    }

    /// Nil, not `.now`. A `.now` fallback is always newer than `doneAt`, so
    /// `Store.resurrectIfNeeded` would revive the item on every single poll
    /// and it could never be dismissed.
    @Test("Unparseable input is nil rather than now")
    func unparseableIsNil() {
        #expect(SentryConnector.parseTimestamp(nil) == nil)
        #expect(SentryConnector.parseTimestamp("") == nil)
        #expect(SentryConnector.parseTimestamp("last tuesday") == nil)
    }

    @Test("An issue with no usable date sorts old, never new")
    func undatedIssueSortsOld() throws {
        let issue = try decodeIssue(#"{"id":"1","title":"Boom","lastSeen":"nonsense"}"#)
        let item = SentryConnector.item(from: issue)
        #expect(item.occurredAt == .distantPast)
        #expect(item.occurredAt < .now)
    }

    func decodeIssue(_ json: String) throws -> SentryConnector.Issue {
        try JSONDecoder().decode(SentryConnector.Issue.self, from: Data(json.utf8))
    }
}

@Suite("Sentry issue mapping")
struct SentryIssueMappingTests {
    func issue(_ json: String) throws -> SentryConnector.Issue {
        try JSONDecoder().decode(SentryConnector.Issue.self, from: Data(json.utf8))
    }

    @Test("A full issue maps onto a RemoteItem")
    func fullIssue() throws {
        let item = SentryConnector.item(
            from: try issue(
                """
                {"id":"4507","title":"TypeError: undefined is not a function",
                 "culprit":"app/checkout.js in submit","shortId":"WEB-4G",
                 "permalink":"https://sentry.io/organizations/acme/issues/4507/",
                 "lastSeen":"2026-08-19T12:34:56.789Z","level":"error",
                 "count":"318","userCount":12,"isUnhandled":true,
                 "project":{"slug":"web","name":"Web"}}
                """))
        #expect(item.externalID == "4507")
        #expect(item.title == "TypeError: undefined is not a function")
        #expect(item.kind == "error")
        #expect(item.url == "https://sentry.io/organizations/acme/issues/4507/")
        #expect(item.actorName == "web")
        #expect(item.highSignal)
        let snippet = try #require(item.snippet)
        #expect(snippet.contains("app/checkout.js in submit"))
        #expect(snippet.contains("318 events"))
        #expect(snippet.contains("12 users"))
        #expect(snippet.contains("WEB-4G"))
    }

    @Test("A sparse issue still maps, without inventing a snippet")
    func sparseIssue() throws {
        let item = SentryConnector.item(from: try issue(#"{"id":"9","title":"Bare"}"#))
        #expect(item.externalID == "9")
        #expect(item.snippet == nil)
        #expect(item.url == nil)
        #expect(item.actorName == nil)
        #expect(!item.highSignal)
    }

    @Test("A single-event issue doesn't say “1 events”")
    func singleEventCount() throws {
        let item = SentryConnector.item(
            from: try issue(#"{"id":"9","title":"Once","count":"1","culprit":"a.js"}"#))
        #expect(item.snippet == "a.js")
    }

    @Test("Only fatal, error and unhandled are high-signal")
    func highSignalLevels() {
        #expect(SentryConnector.highSignal(level: "fatal", isUnhandled: false))
        #expect(SentryConnector.highSignal(level: "error", isUnhandled: nil))
        #expect(SentryConnector.highSignal(level: "info", isUnhandled: true))
        #expect(!SentryConnector.highSignal(level: "warning", isUnhandled: false))
        #expect(!SentryConnector.highSignal(level: "info", isUnhandled: nil))
        #expect(!SentryConnector.highSignal(level: nil, isUnhandled: nil))
    }
}

@Suite("Sentry request building and paging")
struct SentryRequestTests {
    @Test("The default query is Sentry's own For Review tab")
    func defaultQueryIsForReview() {
        #expect(SentryConnector.defaultQuery.contains("is:for_review"))
        #expect(SentryConnector.defaultQuery.contains("is:unresolved"))
    }

    @Test("The issues URL carries query, inbox sort and page size")
    func issuesURL() throws {
        let url = SentryConnector.issuesURL(
            org: "acme", query: "is:unresolved is:for_review", cursor: nil)
        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(
            uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        // Asserted on the string, not `url.path`: Foundation's `path` strips
        // the trailing slash, and Sentry's endpoint needs it.
        #expect(url.absoluteString.contains("/api/0/organizations/acme/issues/?"))
        #expect(byName["query"] == "is:unresolved is:for_review")
        #expect(byName["sort"] == "inbox")
        #expect(byName["limit"] == String(SentryConnector.perPage))
        #expect(byName["cursor"] == nil)
    }

    @Test("A cursor is carried through when paging")
    func issuesURLWithCursor() throws {
        let url = SentryConnector.issuesURL(org: "acme", query: "x", cursor: "0:100:0")
        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "cursor" && $0.value == "0:100:0" })
    }

    @Test("A next link with results follows")
    func cursorFollowsWhenResultsExist() {
        let header = """
            <https://sentry.io/api/0/organizations/acme/issues/?cursor=0:0:1>; rel="previous"; results="false"; cursor="0:0:1", \
            <https://sentry.io/api/0/organizations/acme/issues/?cursor=0:100:0>; rel="next"; results="true"; cursor="0:100:0"
            """
        #expect(SentryConnector.nextCursor(inLinkHeader: header) == "0:100:0")
    }

    /// `results="false"` means the next page is empty. Following it costs a
    /// round trip to learn nothing.
    @Test("A next link with no results stops")
    func cursorStopsWhenNoResults() {
        let header =
            #"<https://sentry.io/x>; rel="next"; results="false"; cursor="0:100:0""#
        #expect(SentryConnector.nextCursor(inLinkHeader: header) == nil)
    }

    @Test("A missing or link-less header stops")
    func cursorStopsWithoutHeader() {
        #expect(SentryConnector.nextCursor(inLinkHeader: nil) == nil)
        #expect(SentryConnector.nextCursor(inLinkHeader: "") == nil)
        #expect(
            SentryConnector.nextCursor(
                inLinkHeader: #"<https://sentry.io/x>; rel="previous"; results="true""#) == nil)
    }
}

@Suite("Sentry failure messages")
struct SentryProblemTests {
    /// Rule 4: every failure says what to do about it, not just what broke.
    @Test("Each status names the fix")
    func statusesNameTheFix() {
        let unauthorized = SentryConnector.problem(
            forHTTPStatus: 401, body: nil, retryAfter: nil, org: "acme")
        #expect(unauthorized.contains("event:read"))

        let forbidden = SentryConnector.problem(
            forHTTPStatus: 403, body: nil, retryAfter: nil, org: "acme")
        #expect(forbidden.contains("scope"))

        let missing = SentryConnector.problem(
            forHTTPStatus: 404, body: nil, retryAfter: nil, org: "acme")
        #expect(missing.contains("acme"))
        #expect(missing.contains("slug"))

        let limited = SentryConnector.problem(
            forHTTPStatus: 429, body: nil, retryAfter: "30", org: "acme")
        #expect(limited.contains("30"))
    }

    @Test("An unknown status still reports the number and the body")
    func unknownStatus() {
        let message = SentryConnector.problem(
            forHTTPStatus: 503, body: "upstream down", retryAfter: nil, org: "acme")
        #expect(message.contains("503"))
        #expect(message.contains("upstream down"))
    }
}

// MARK: - Apple Mail

@Suite("Mail automation permission mapping")
struct MailAutomationAuthorizationTests {
    typealias Auth = MailAutomationAuthorization

    /// The function that decides whether the source polls at all. Every wrong
    /// answer it can give is silent, which is why it is pure and tested
    /// rather than trusted.
    @Test("Each OSStatus maps to the right verdict")
    func statusMapping() {
        #expect(Auth.outcome(forStatus: 0) == .granted)
        #expect(Auth.outcome(forStatus: -1744) == .notRequested)
        #expect(Auth.outcome(forStatus: -1743) == .blocked(Auth.deniedMessage))
        #expect(Auth.outcome(forStatus: -600) == .mailNotRunning)
        #expect(Auth.outcome(forStatus: -609) == .mailNotRunning)
    }

    /// An unrecognised status must not read as permission. The precedent is
    /// `BannerAuthorization.settledOutcome`, which refuses to assume delivery
    /// for the same reason.
    @Test("An unknown status blocks and reports its number")
    func unknownStatusBlocks() {
        let outcome = Auth.outcome(forStatus: -12345)
        #expect(outcome != .granted)
        #expect(outcome.allowsFetch == false)
        #expect(outcome.message?.contains("-12345") == true)
    }

    /// "You just clicked Don't Allow" and "this was refused at some point"
    /// are both -1743 to macOS and need different sentences.
    @Test("A just-declined prompt reads differently from an old refusal")
    func declineIsDistinctFromDenial() {
        #expect(Auth.requestOutcome(forStatus: -1743) == .blocked(Auth.declinedMessage))
        #expect(Auth.outcome(forStatus: -1743) == .blocked(Auth.deniedMessage))
        #expect(Auth.declinedMessage != Auth.deniedMessage)
        // Anything that isn't a refusal is mapped identically either way.
        #expect(Auth.requestOutcome(forStatus: 0) == .granted)
        #expect(Auth.requestOutcome(forStatus: -600) == .mailNotRunning)
    }

    /// Only a granted verdict may fetch — including declining to fetch when
    /// Mail is closed, because `tell application "Mail"` launches Mail and a
    /// launch from a background poll is the last path to an Automation dialog
    /// the user cannot connect to anything they did.
    @Test("Only granted permits a poll")
    func onlyGrantedPolls() {
        #expect(Auth.Outcome.granted.allowsFetch)
        #expect(!Auth.Outcome.notRequested.allowsFetch)
        #expect(!Auth.Outcome.blocked("nope").allowsFetch)
        #expect(!Auth.Outcome.mailNotRunning.allowsFetch)
    }

    /// Rule 5: the refusal is the whole point. A blocked poll that returned
    /// no reason would be indistinguishable from an empty inbox.
    @Test("Every non-granted verdict carries a reason")
    func refusalsExplainThemselves() {
        #expect(Auth.Outcome.granted.fetchRefusal == nil)
        for outcome: Auth.Outcome in [
            .notRequested, .blocked(Auth.deniedMessage), .mailNotRunning,
        ] {
            let refusal = outcome.fetchRefusal
            #expect(refusal != nil)
            #expect(refusal?.isEmpty == false)
        }
    }

    /// The not-yet-asked state has two wordings on purpose: the source status
    /// has to say where the button is, the UI beside the button must not.
    @Test("The not-requested advice points at the button; the UI copy doesn't")
    func notRequestedHasTwoWordings() {
        #expect(Auth.notRequestedAdvice.contains("Allow Mail Access"))
        #expect(!Auth.notRequestedMessage.contains("Allow Mail Access"))
        #expect(Auth.Outcome.notRequested.fetchRefusal == Auth.notRequestedAdvice)
    }

    /// Two wordings for one condition is how a user ends up believing they
    /// have two problems. `AppleMailConnector.explain(-1743)` says this when a
    /// live poll hits the refusal; this says it before one ever runs.
    @Test("The denial copy agrees with the connector's own -1743 message")
    func denialAgreesWithConnector() {
        let connector = AppleMailConnector.explain(appleScriptError: -1743)
        for message in [connector, Auth.deniedMessage] {
            #expect(message.contains("Automation"))
            #expect(message.contains("permanently empty"))
        }
    }

    /// The copy the user reads *instead of* being ambushed. These assertions
    /// are about substance, not phrasing: each bullet is a claim about what
    /// `fetchScript` and `markDoneScript` actually do, and a reassurance that
    /// drifts out of date is worse than no reassurance at all.
    @Test("The preflight makes the claims it needs to")
    func preflightSaysTheLoadBearingThings() {
        let preflight = Auth.preflight
        #expect(!preflight.title.isEmpty)
        #expect(preflight.bullets.count == 3)
        #expect(preflight.bullets.allSatisfy { !$0.isEmpty })

        let everything =
            ([preflight.title, preflight.lead, preflight.promptNote,
              preflight.coldNote] + preflight.bullets)
            .joined(separator: " ")

        // True of fetchScript: subject, sender and date; never the body.
        #expect(everything.contains("never the body"))
        // True of markDoneScript: read status, and the flag only if a flag
        // queued the row.
        #expect(everything.contains("unflags it"))
        // The connector has no network path at all.
        #expect(everything.contains("Nothing leaves this Mac"))
        // The dialog about to appear is macOS's, not the app's.
        #expect(everything.contains("macOS"))
        // Declining is survivable but looks like nothing — say so first.
        #expect(everything.contains("empty"))
        // A cold Mail costs ~12s and must not read as a broken source.
        #expect(everything.contains("ten seconds"))
    }
}

@Suite("Apple Mail script building")
struct AppleMailScriptTests {
    @Test("Flagged-only asks Mail only about flags")
    func flaggedOnly() {
        let script = AppleMailConnector.fetchScript(
            scope: .init(flagged: true, unread: false, mailbox: ""))
        #expect(script.contains("flagged status is true"))
        #expect(!script.contains("read status is false"))
        #expect(script.contains("messages of inbox"))
    }

    /// A flagged *and* unread message must arrive once. Without the extra
    /// clause it arrives twice, with two kinds and two contradictory done
    /// gestures.
    @Test("Both scopes exclude flagged from the unread clause")
    func bothScopesDeduplicate() {
        let script = AppleMailConnector.fetchScript(
            scope: .init(flagged: true, unread: true, mailbox: ""))
        #expect(script.contains("read status is false and flagged status is false"))
    }

    @Test("Unread-only doesn't filter on flags at all")
    func unreadOnly() {
        let script = AppleMailConnector.fetchScript(
            scope: .init(flagged: false, unread: true, mailbox: ""))
        #expect(script.contains("whose read status is false)"))
        #expect(!script.contains("flagged status is false"))
    }

    @Test("A named mailbox is quoted, and quotes in the name are escaped")
    func mailboxQuoting() {
        let script = AppleMailConnector.fetchScript(
            scope: .init(flagged: true, unread: false, mailbox: "Work"))
        #expect(script.contains("mailbox \"Work\""))
        #expect(AppleMailConnector.quoted("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(AppleMailConnector.quoted("back\\slash") == "\"back\\\\slash\"")
    }

    @Test("The cap is applied in the script, newest first")
    func capIsInScript() {
        let script = AppleMailConnector.fetchScript(
            scope: .init(flagged: true, unread: false, mailbox: ""))
        #expect(script.contains("items 1 thru \(AppleMailConnector.maxMessages)"))
    }

    /// "I dealt with this email" always means read; the flag is cleared only
    /// when a flag is what queued it.
    @Test("Marking done always marks read, and unflags only when flagged")
    func markDoneScripts() {
        let flagged = AppleMailConnector.markDoneScript(
            handle: .init(mailID: 42, messageID: nil, unflag: true))
        #expect(flagged.contains("set read status of m to true"))
        #expect(flagged.contains("set flagged status of m to false"))

        let unread = AppleMailConnector.markDoneScript(
            handle: .init(mailID: 42, messageID: nil, unflag: false))
        #expect(unread.contains("set read status of m to true"))
        #expect(!unread.contains("flagged status"))
    }

    /// The -1719 bug: `first message … whose` raises "Invalid index" when the
    /// filter matches nothing, which names nothing. Counting a whose-list
    /// returns 0 instead, so a miss becomes a fact with a sentence attached.
    @Test("Marking done never uses the idiom that raised -1719")
    func markDoneAvoidsFirstWhose() {
        let script = AppleMailConnector.markDoneScript(
            handle: .init(mailID: 42, messageID: "a@b", unflag: true,
                          account: "ACCT-1", mailbox: "INBOX"))
        #expect(!script.contains("first message"))
        #expect(script.contains("count of hits"))
        #expect(script.contains(AppleMailConnector.notFoundMessage))
    }

    /// Mail's `id` is per-mailbox, so a bare id in the unified inbox can name
    /// a different message in another account.
    @Test("Marking done scopes the lookup to the account and mailbox it came from")
    func markDoneScopesLookup() {
        let script = AppleMailConnector.markDoneScript(
            handle: .init(mailID: 42, messageID: "a@b", unflag: false,
                          account: "ACCT-1", mailbox: "Work"))
        #expect(script.contains("account id \"ACCT-1\""))
        #expect(script.contains("mailbox \"Work\""))
        // RFC id and bare id remain as ordered fallbacks.
        #expect(script.contains("whose message id is \"a@b\""))
        #expect(script.contains("whose id is 42"))
    }

    /// A handle written by 0.3.0 has no account or mailbox; it must still
    /// produce a working script rather than crash or emit `account id ""`.
    @Test("A 0.3.0 handle still marks done, via the fallbacks")
    func markDoneWithLegacyHandle() {
        let script = AppleMailConnector.markDoneScript(
            handle: .init(mailID: 42, messageID: nil, unflag: false))
        #expect(!script.contains("account id"))
        #expect(script.contains("whose id is 42"))
        #expect(script.contains("set read status of m to true"))
    }
}

@Suite("Apple Mail output parsing")
struct AppleMailParsingTests {
    let field = AppleMailConnector.fieldSeparator
    let record = AppleMailConnector.recordSeparator

    func output(truncated: String, records: [[String]]) -> String {
        ([truncated] + records.map { $0.joined(separator: field) })
            .joined(separator: record) + record
    }

    @Test("A flagged record becomes a high-signal item with a message link")
    func flaggedRecord() throws {
        let raw = output(
            truncated: "0",
            records: [
                [
                    "826216", "abc123@mail.example.com", "Contract for review",
                    "\"Ada Lovelace\" <ada@example.com>", "2026-08-19 14:32:07",
                    "true", "false",
                ]
            ])
        let (items, truncated) = AppleMailConnector.items(fromScriptOutput: raw)
        #expect(!truncated)
        let item = try #require(items.first)
        #expect(item.externalID == "abc123@mail.example.com")
        #expect(item.kind == "flagged")
        #expect(item.title == "Contract for review")
        #expect(item.actorName == "Ada Lovelace")
        #expect(item.highSignal)
        #expect(item.url == "message://%3cabc123@mail.example.com%3e")
        let handle = try #require(AppleMailConnector.MessageHandle(payload: item.payload))
        #expect(handle.mailID == 826216)
        #expect(handle.unflag)
    }

    @Test("Account and mailbox round-trip into the handle when present")
    func accountAndMailboxRoundTrip() throws {
        let raw = output(
            truncated: "0",
            records: [
                ["826216", "a@b", "Subject", "s@e", "2026-08-19 14:32:07",
                 "true", "false", "ACCT-1", "INBOX"]
            ])
        let item = try #require(AppleMailConnector.items(fromScriptOutput: raw).items.first)
        let handle = try #require(AppleMailConnector.MessageHandle(payload: item.payload))
        #expect(handle.account == "ACCT-1")
        #expect(handle.mailbox == "INBOX")
    }

    /// 0.3.0 wrote seven fields. Those rows must keep parsing.
    @Test("A seven-field record from 0.3.0 still parses, with no account")
    func sevenFieldRecordStillParses() throws {
        let raw = output(
            truncated: "0",
            records: [["7", "a@b", "S", "s@e", "2026-08-19 09:00:00", "false", "false"]])
        let item = try #require(AppleMailConnector.items(fromScriptOutput: raw).items.first)
        let handle = try #require(AppleMailConnector.MessageHandle(payload: item.payload))
        #expect(handle.account == nil)
        #expect(handle.mailbox == nil)
        #expect(handle.mailID == 7)
    }

    @Test("An unread record marks read rather than unflagging")
    func unreadRecord() throws {
        let raw = output(
            truncated: "0",
            records: [
                ["7", "x@y", "Standup notes", "bob@example.com", "2026-08-19 09:00:00", "false", "false"]
            ])
        let item = try #require(AppleMailConnector.items(fromScriptOutput: raw).items.first)
        #expect(item.kind == "unread")
        #expect(item.actorName == "bob@example.com")
        #expect(!item.highSignal)
        let handle = try #require(AppleMailConnector.MessageHandle(payload: item.payload))
        #expect(!handle.unflag)
    }

    /// Mail's numeric id changes on a reindex, so the RFC Message-ID is the
    /// external id when there is one — and the fallback must still be unique.
    @Test("A message with no RFC id falls back to Mail's own id")
    func missingMessageID() throws {
        let raw = output(
            truncated: "0",
            records: [["99", "", "No id", "a@b", "2026-08-19 09:00:00", "false", "false"]])
        let item = try #require(AppleMailConnector.items(fromScriptOutput: raw).items.first)
        #expect(item.externalID == "mail-id:99")
        #expect(item.url == nil)
    }

    /// `.remoteTruth` archives anything missing from a snapshot, so a capped
    /// snapshot must report itself as incomplete.
    @Test("The truncation flag survives parsing")
    func truncationFlag() {
        let raw = output(
            truncated: "1",
            records: [["1", "a@b", "S", "s@e", "2026-08-19 09:00:00", "false", "false"]])
        #expect(AppleMailConnector.items(fromScriptOutput: raw).truncated)
    }

    @Test("Empty and malformed records are skipped, not crashed on")
    func malformedRecords() {
        #expect(AppleMailConnector.items(fromScriptOutput: "").items.isEmpty)
        #expect(AppleMailConnector.items(fromScriptOutput: "0").items.isEmpty)
        #expect(AppleMailConnector.item(fromRecord: "too\u{1F}few") == nil)
        #expect(
            AppleMailConnector.item(
                fromRecord: "notanumber\u{1F}a\u{1F}b\u{1F}c\u{1F}d\u{1F}e\u{1F}f") == nil)
    }

    @Test("A subject Mail refused still produces a visible row")
    func undescribedMessageIsVisible() throws {
        let raw = output(
            truncated: "0",
            records: [
                ["55", "", AppleMailConnector.undescribedTitle, "", "", "false", "false"]
            ])
        let item = try #require(AppleMailConnector.items(fromScriptOutput: raw).items.first)
        #expect(item.title == AppleMailConnector.undescribedTitle)
        #expect(item.occurredAt == .distantPast)
    }

    @Test("A separator-bearing subject survives, because separators are control codes")
    func subjectWithPunctuation() throws {
        let raw = output(
            truncated: "0",
            records: [
                ["1", "a@b", "Re: pipe | tab\tand, comma", "s@e", "2026-08-19 09:00:00",
                 "false", "false"]
            ])
        let item = try #require(AppleMailConnector.items(fromScriptOutput: raw).items.first)
        #expect(item.title == "Re: pipe | tab\tand, comma")
    }
}

@Suite("Apple Mail field helpers")
struct AppleMailFieldTests {
    @Test("Component dates parse in the Mac's own calendar")
    func componentDates() throws {
        let date = try #require(
            AppleMailConnector.date(fromComponents: "2026-08-19 14:32:07"))
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 19)
        #expect(parts.hour == 14)
        #expect(parts.minute == 32)
        #expect(parts.second == 7)
    }

    @Test("A date Mail didn't give is nil, not now")
    func badDates() {
        #expect(AppleMailConnector.date(fromComponents: "") == nil)
        #expect(AppleMailConnector.date(fromComponents: "2026-08-19") == nil)
        #expect(
            AppleMailConnector.date(fromComponents: "Wednesday, 19 August 2026") == nil)
    }

    @Test("Sender display names are unwrapped, addresses kept as-is")
    func senderNames() {
        #expect(
            AppleMailConnector.displayName(fromSender: "\"Ada Lovelace\" <ada@example.com>")
                == "Ada Lovelace")
        #expect(
            AppleMailConnector.displayName(fromSender: "Ada Lovelace <ada@example.com>")
                == "Ada Lovelace")
        #expect(
            AppleMailConnector.displayName(fromSender: "<ada@example.com>")
                == "ada@example.com")
        #expect(
            AppleMailConnector.displayName(fromSender: "ada@example.com")
                == "ada@example.com")
        #expect(AppleMailConnector.displayName(fromSender: "  ") == nil)
    }

    /// Verified 2026-08-19 that `message://%3c…%3e` resolves to Mail.app.
    @Test("Message links wrap the id in encoded angle brackets")
    func messageLinks() throws {
        let url = try #require(
            AppleMailConnector.messageURL(messageID: "CAF=1234@mail.gmail.com"))
        #expect(url.scheme == "message")
        #expect(url.absoluteString.hasPrefix("message://%3c"))
        #expect(url.absoluteString.hasSuffix("%3e"))
        // Already-bracketed ids from Mail must not double up.
        let bracketed = try #require(
            AppleMailConnector.messageURL(messageID: "<abc@d.example>"))
        #expect(!bracketed.absoluteString.contains("%3c%3c"))
        #expect(AppleMailConnector.messageURL(messageID: "") == nil)
        #expect(AppleMailConnector.messageURL(messageID: "<>") == nil)
    }

    /// The failure that matters: refusing the Apple event looks exactly like
    /// an empty inbox, so it must name itself and the fix.
    @Test("A refused Apple event explains itself")
    func refusedAppleEvent() {
        let denied = AppleMailConnector.explain(appleScriptError: -1743)
        #expect(denied.contains("Automation"))
        #expect(denied.lowercased().contains("empty"))

        #expect(AppleMailConnector.explain(appleScriptError: -600).contains("running"))
        #expect(AppleMailConnector.explain(appleScriptError: -1728).contains("-1728"))
        // -1719 was the 0.3.0 markDone failure; it must name a cause now.
        #expect(AppleMailConnector.explain(appleScriptError: -1719).contains("moved or deleted"))
        #expect(AppleMailConnector.explain(appleScriptError: 42).contains("42"))
    }
}

@Suite("New sources are configurable")
struct NewSourceCatalogTests {
    @Test("Sentry and Apple Mail are in the catalog with usable fields")
    func catalogEntries() throws {
        let sentry = try #require(ConnectorCatalog.descriptor(for: "sentry"))
        #expect(sentry.fields.contains { $0.key == "token" && $0.isSecret })
        #expect(sentry.fields.contains { $0.key == "org" && !$0.isSecret })
        // Resolving in Sentry is team-visible, so it must be opt-in.
        let resolve = try #require(sentry.fields.first { $0.key == "resolveOnDone" })
        #expect(resolve.isToggle)
        #expect(!resolve.defaultOn)

        let mail = try #require(ConnectorCatalog.descriptor(for: "appleMail"))
        // Nothing to paste: an entirely local source.
        #expect(mail.fields.allSatisfy { !$0.isSecret })
        let flagged = try #require(mail.fields.first { $0.key == "flagged" })
        #expect(flagged.defaultOn)
        // Unread-in-inbox would bury every other source.
        let unread = try #require(mail.fields.first { $0.key == "unread" })
        #expect(!unread.defaultOn)
    }

    @Test("Both explain themselves before asking for anything")
    func bothExplainThemselves() throws {
        for kind in ["sentry", "appleMail"] {
            let descriptor = try #require(ConnectorCatalog.descriptor(for: kind))
            #expect(!descriptor.setupSteps.isEmpty)
            #expect(!descriptor.authNote.isEmpty)
        }
    }

    @Test("Apple Mail is the one kind that can't be added twice")
    func appleMailIsSingleton() throws {
        // A Mac has exactly one Mail.app database, unlike GitHub or Linear,
        // where multiple accounts are legitimately different sources.
        let mail = try #require(ConnectorCatalog.descriptor(for: "appleMail"))
        #expect(!mail.allowsMultiple)
        for kind in ConnectorCatalog.all where kind.id != "appleMail" {
            #expect(kind.allowsMultiple, "\(kind.displayName) should allow multiple sources")
        }
    }
}

// MARK: - Sparkle updates (Sources/App/Support/UpdateController.swift)

/// A build that cannot update is the rule-5 case for Sparkle: the app checks,
/// finds it has no way to verify a download, and does nothing — which looks
/// exactly like being up to date. These are the sentences that keep it from
/// being silent.
@Suite("Update configuration problems")
struct UpdateConfigurationTests {
    // configurationProblem only asks whether a key is present and non-blank —
    // Sparkle validates the real thing — so this is deliberately not shaped
    // like a key, to keep secret scanners quiet on a repo meant to go public.
    private static let key = "EXAMPLE-not-a-real-signing-key"
    private static let feed = "https://example.com/appcast.xml"

    @Test("A build with both a feed and a key has no problem to report")
    func fullyConfigured() {
        #expect(
            UpdateController.configurationProblem(
                info: ["SUFeedURL": Self.feed, "SUPublicEDKey": Self.key]) == nil)
    }

    /// The case a clone hits: `scripts/sparkle-keys.sh` has never been run, so
    /// the build has a feed but nothing to verify a download against. It must
    /// say so, and say what to run — not report a signature failure later,
    /// which reads as a corrupted download.
    @Test("A missing signing key is explained, and names the script that fixes it")
    func missingSigningKey() throws {
        let problem = try #require(
            UpdateController.configurationProblem(info: ["SUFeedURL": Self.feed]))
        #expect(problem.contains("sparkle-keys.sh"))
        #expect(problem.contains("built it yourself"))
    }

    @Test("A missing feed URL is explained")
    func missingFeed() throws {
        let problem = try #require(
            UpdateController.configurationProblem(info: ["SUPublicEDKey": Self.key]))
        #expect(problem.contains("no update feed"))
    }

    /// A key that is present but blank is the same as absent, and is what an
    /// unreplaced placeholder in project.yml would produce.
    @Test("Whitespace-only values count as missing")
    func blankValuesAreMissing() {
        #expect(
            UpdateController.configurationProblem(
                info: ["SUFeedURL": Self.feed, "SUPublicEDKey": "   "]) != nil)
        #expect(UpdateController.configurationProblem(info: [:]) != nil)
        #expect(UpdateController.configurationProblem(info: nil) != nil)
    }
}

/// Sparkle reports "nothing new" and "the user cancelled" through the same
/// callback as real failures. Printing those in red would train you to ignore
/// the red text, which is the one thing it cannot afford.
@Suite("Update failure explanations")
struct UpdateFailureExplanationTests {
    private func sparkleError(_ code: Int) -> NSError {
        NSError(
            domain: SUSparkleErrorDomain, code: code,
            userInfo: [NSLocalizedDescriptionKey: "described by Sparkle"])
    }

    @Test("No update found is not a failure")
    func noUpdateIsSilent() {
        #expect(UpdateController.explain(sparkleError(1001)) == nil)
    }

    @Test("A cancelled or postponed install is not a failure")
    func userChoicesAreSilent() {
        #expect(UpdateController.explain(sparkleError(4007)) == nil)
        #expect(UpdateController.explain(sparkleError(4008)) == nil)
    }

    /// A download that fails its signature check is the one failure that must
    /// never be summarised as "couldn't update" — it says the bytes did not
    /// come from the key this build trusts.
    @Test("A signature failure says the update was not installed")
    func signatureFailureIsLoud() throws {
        let message = try #require(UpdateController.explain(sparkleError(3001)))
        #expect(message.contains("signature"))
        #expect(message.contains("not installed"))
    }

    @Test("An unreadable feed points at the download as a way out")
    func feedFailureOffersFallback() throws {
        let message = try #require(UpdateController.explain(sparkleError(1002)))
        #expect(message.contains("update feed"))
        #expect(message.contains("GitHub"))
    }

    /// Network trouble arrives as an NSURLError, not a Sparkle error, and its
    /// own description is already a decent sentence.
    @Test("Errors from outside Sparkle are passed through")
    func foreignErrorsPassThrough() throws {
        let offline = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        let message = try #require(UpdateController.explain(offline))
        #expect(message.contains("offline"))
    }
}

/// A credential that fails to save is indistinguishable from one that saved
/// — the sheet closes, the field still shows the token, and the source then
/// fails to authenticate for a reason nothing on screen accounts for. These
/// strings are the only account anyone gets, so each one has to name the
/// field and say what to do next rather than printing a bare OSStatus.
struct KeychainExplainTests {
    @Test("The failing field is named, not the internal key")
    func namesTheField() {
        let message = Keychain.explain(errSecAuthFailed, key: "\(UUID()).pat")
        #expect(message.contains("pat"))
        #expect(!message.contains("OSStatus"))
    }

    @Test("A locked keychain says how to unlock it")
    func lockedSaysWhatToDo() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed] {
            let message = Keychain.explain(status, key: "src.userToken")
            #expect(message.contains("Keychain Access"))
        }
    }

    @Test("A leftover item points at the item to remove")
    func duplicateNamesTheItem() {
        let message = Keychain.explain(errSecDuplicateItem, key: "src.apiKey")
        #expect(message.contains("lol.bgreen.inboxandchill"))
        #expect(message.contains("src.apiKey"))
    }

    @Test("A cancelled prompt reads as cancelled, not as a fault")
    func cancellationIsNotAnError() {
        let message = Keychain.explain(errSecUserCanceled, key: "src.password")
        #expect(message.contains("cancelled"))
    }

    @Test("An unexpected status still explains itself")
    func unknownStatusStillReads() {
        // Never a bare number: -25260 tells the user nothing on its own.
        let message = Keychain.explain(-25260, key: "src.token")
        #expect(message.hasPrefix("Couldn't save token"))
        #expect(message.count > "Couldn't save token".count + 8)
    }
}

// MARK: - Row expansion (Sources/App/UI/ExpandingText.swift)

/// The selected row opens to a paragraph and every other row stays on one
/// line. The clamp is what decides that, and it runs before either ruler has
/// measured anything — a row scrolling into a `LazyVStack` renders at least
/// one frame with no measurement at all, so the unmeasured cases are the
/// ones that would show as a flicker.
struct ExpandingTextClampTests {
    private let estimate: CGFloat = 15

    @Test("An unmeasured closed row falls back to the estimate, not to zero")
    func unmeasuredClosedUsesEstimate() {
        #expect(
            ExpandingText.clamp(
                isExpanded: false, collapsed: nil, expanded: nil,
                estimate: estimate) == estimate)
    }

    @Test("An unmeasured open row takes its natural height instead")
    func unmeasuredOpenIsUnclamped() {
        // Clamping it to the one-line estimate is what made a freshly
        // rendered row paint one line tall and then jump to four with no
        // animation to explain it.
        #expect(
            ExpandingText.clamp(
                isExpanded: true, collapsed: nil, expanded: nil,
                estimate: estimate) == nil)
    }

    @Test("Selection opens the row to the full measured height")
    func selectedOpens() {
        #expect(
            ExpandingText.clamp(
                isExpanded: true, collapsed: 15, expanded: 62,
                estimate: estimate) == 62)
    }

    @Test("Losing selection closes it back to one line")
    func deselectedCloses() {
        #expect(
            ExpandingText.clamp(
                isExpanded: false, collapsed: 15, expanded: 62,
                estimate: estimate) == 15)
    }

    @Test("Text that already fits never opens onto empty space")
    func shortTextDoesNotGrow() {
        // A one-line snippet measures the same both ways; the row must not
        // gain a gap under it just because it holds the selection.
        #expect(
            ExpandingText.clamp(
                isExpanded: true, collapsed: 15, expanded: 15,
                estimate: estimate) == 15)
        #expect(
            ExpandingText.clamp(
                isExpanded: false, collapsed: 15, expanded: 15,
                estimate: estimate) == 15)
    }

    @Test("D opens the row to the whole message")
    func fullOpensToTheWholeMessage() {
        #expect(
            ExpandingText.clamp(
                isExpanded: true, isFull: true, collapsed: 15, expanded: 62,
                full: 210, estimate: estimate) == 210)
    }

    @Test("Closing the full view returns to the four-line height")
    func fullClosesBackToTheParagraph() {
        // Both numbers exist before either press, which is the whole reason
        // the toggle animates in both directions rather than snapping.
        #expect(
            ExpandingText.clamp(
                isExpanded: true, isFull: false, collapsed: 15, expanded: 62,
                full: 210, estimate: estimate) == 62)
    }

    @Test("An unmeasured full row takes its natural height, not four lines")
    func unmeasuredFullIsUnclamped() {
        // A row that scrolls in already full paints before its ruler lands.
        // Clamping it to the paragraph height would crop the message and
        // then jump — the same bug the open case above already records.
        #expect(
            ExpandingText.clamp(
                isExpanded: true, isFull: true, collapsed: 15, expanded: 62,
                full: nil, estimate: estimate) == nil)
    }

    @Test("An unselected row stays on one line however D was left")
    func fullNeverEscapesTheSelection() {
        // The panel closes the expansion whenever the selection moves, but
        // the clamp must not depend on that having happened: a row without
        // the selection is on its one line, full flag or not.
        #expect(
            ExpandingText.clamp(
                isExpanded: false, isFull: true, collapsed: 15, expanded: 62,
                full: 210, estimate: estimate) == 15)
    }

    @Test("A clamped copy is handed a prefix, not a whole Slack message")
    func clampedCopiesAreBounded() {
        // Both clamped copies are laid out for every row on screen, so what
        // they are *handed* is the cost — not what they end up showing.
        let long = String(repeating: "a", count: 4_000)
        #expect(
            ExpandingText.clampedPrefix(long, lines: 1, charsPerLine: 240)
                .count == 240)
        #expect(
            ExpandingText.clampedPrefix(long, lines: 4, charsPerLine: 240)
                .count == 960)
    }

    @Test("The prefix never becomes the thing that truncates")
    func prefixLeavesTheClampInCharge() {
        // If the prefix were tight enough to cut the text itself, the "…"
        // would sit on text that had already ended — the row would claim
        // there is more when there is not. The budget is several times the
        // ~55 characters a 420pt row actually fits, so the clamp wins.
        let fourLinesOfPanel = String(repeating: "a ", count: 130)  // ~260
        #expect(
            ExpandingText.clampedPrefix(fourLinesOfPanel, lines: 4)
                == fourLinesOfPanel)
        // Short text is passed through untouched.
        #expect(ExpandingText.clampedPrefix("hi", lines: 4) == "hi")
    }

    @Test("A single line is never cropped by a stale estimate")
    func closedHeightNeverCropsTheMeasuredLine() {
        // Estimate too tall: the measured line wins, so no gap.
        #expect(
            ExpandingText.clamp(
                isExpanded: false, collapsed: 15, expanded: 15, estimate: 40)
                == 15)
        // Nothing measured yet and one real line: the estimate is what
        // keeps the descenders on screen.
        #expect(ExpandingText.estimatedLineHeight(size: 12) >= 12)
    }
}

// MARK: - Row focus weights (Sources/App/UI/PanelSupport.swift)

/// The row's selection background is tuned by eye, but the *relationships*
/// between the states are the part a later tweak could quietly break —
/// selection sinking to or below hover would make ↑/↓ navigation ambiguous,
/// and the panel is keyboard-first.
struct RowFocusTests {
    @Test("An idle row paints nothing at all")
    func idleRowIsBlank() {
        let focus = RowFocus.resolve(
            isSelected: false, isHovering: false, isKey: true)
        #expect(focus == .unfocused)
        #expect(!focus.hasBaseFill)
        #expect(focus.fill == 0)
        #expect(focus.border == 0)
    }

    @Test("Hover is a bare fill — the border belongs to selection alone")
    func hoverHasNoBorder() {
        let focus = RowFocus.resolve(
            isSelected: false, isHovering: true, isKey: true)
        #expect(focus == .hovered)
        #expect(focus.hasBaseFill)
        #expect(focus.border == 0)
    }

    /// Both states can land on the same row: the mouse rests on the row the
    /// keyboard has selected. Selection must still win.
    @Test("Selection outweighs hover in both key states, hover or not")
    func selectionAlwaysOutweighsHover() {
        for isKey in [true, false] {
            for isHovering in [true, false] {
                let focus = RowFocus.resolve(
                    isSelected: true, isHovering: isHovering, isKey: isKey)
                // Same `.quaternary` floor as hover, so these two weights
                // are what selection adds on top of it.
                #expect(focus.hasBaseFill)
                #expect(focus.fill > RowFocus.hovered.fill)
                #expect(focus.border > RowFocus.hovered.border)
            }
        }
    }

    @Test("Losing key status dims the selection without erasing it")
    func inactiveSelectionIsDimmerButPresent() {
        let key = RowFocus.resolve(
            isSelected: true, isHovering: false, isKey: true)
        let notKey = RowFocus.resolve(
            isSelected: true, isHovering: false, isKey: false)
        #expect(key == .selected)
        #expect(notKey == .selectedInactive)
        #expect(notKey.fill < key.fill)
        #expect(notKey.border < key.border)
        #expect(notKey.fill > 0)
        #expect(notKey.border > 0)
    }

    /// Guards the "quiet" half of the brief from the opposite drift: these
    /// are meant to be tonal nudges, not the blue slab they replaced.
    @Test("Every weight stays in subtle-tint territory")
    func weightsStaySubtle() {
        for focus in [RowFocus.hovered, .selected, .selectedInactive] {
            #expect(focus.fill < 0.2)
            #expect(focus.border < 0.25)
        }
    }
}


// MARK: - JSONPollerConnector (Sources/App/Connectors/JSONPollerConnector.swift)
//
// Network calls aren't testable here. `fetch()` guards on a nil `URL` before
// touching the network, so that path is deterministic and network-free.
// Mapping parsing happens in `init` but is stored in a private property with
// no accessor, so it can only be exercised indirectly: constructing a
// connector must not crash regardless of how malformed the mapping string
// is, and the connector's other pure, constant properties are checked
// directly.

struct JSONPollerConnectorTests {
    @Test func fetchThrowsForEmptyURLString() async {
        let connector = JSONPollerConnector(
            sourceID: "s", urlString: "", mapping: "id=id,title=title")
        await #expect(throws: (any Error).self) {
            _ = try await connector.fetch()
        }
    }

    @Test func fetchThrowsForUnparsableURLString() async {
        // A raw space is not a valid (unescaped) URL character, so
        // `URL(string:)` returns nil and `fetch()` must throw before any
        // network access.
        let connector = JSONPollerConnector(
            sourceID: "s", urlString: "not a url with raw spaces",
            mapping: "id=id,title=title")
        await #expect(throws: (any Error).self) {
            _ = try await connector.fetch()
        }
    }

    @Test func constantConnectorMetadataIsCorrect() {
        let connector = JSONPollerConnector(
            sourceID: "my-feed", urlString: "https://example.com/feed.json",
            mapping: "id=id,title=title,url=url,time=created_at")
        #expect(connector.sourceID == "my-feed")
        #expect(connector.sourceKind == "jsonPoller")
        #expect(connector.capabilities == [.remoteTruth])
        #expect(connector.pollInterval == 120)
    }

    @Test func initDoesNotCrashOnMalformedMappingStrings() {
        // Exercises the mapping parser (split on "," then "=") indirectly:
        // it just needs to survive garbage input without trapping. There is
        // no public accessor to assert the parsed contents directly (see
        // report: would need a `mapping: [String: String]` accessor, or a
        // free function, to test the parse result itself).
        let malformedMappings = [
            "",
            ",,,",
            "novalue=",
            "=noKey",
            "id=id,",
            "id=id=extra=parts",
            "  id = id ,  title = title  ",
            "id=id,id=id2",  // duplicate key, last one should just win
        ]
        for mapping in malformedMappings {
            let connector = JSONPollerConnector(
                sourceID: "s", urlString: "https://example.com", mapping: mapping)
            #expect(connector.sourceKind == "jsonPoller")
        }
    }
}

// MARK: - JSONPollerConnector timestamp parsing
// (Sources/App/Connectors/JSONPollerConnector.swift)
//
// Regression coverage for an undismissable-item bug. `fetch()` used a default
// `ISO8601DateFormatter()`, whose option set parses whole seconds but returns
// nil for fractional ones — so any feed with ".789Z" timestamps (Sentry's
// `lastSeen`, among many) fell through to `.now`. Because this connector
// declares `.remoteTruth` without `.markDone`, a dismissed item stays in
// every snapshot, and `Store.resurrectIfNeeded` revives a done item whose
// `remote.occurredAt > doneAt` — which `.now` always is. The item could not
// be cleared until it left the feed.

struct JSONPollerTimestampTests {
    @Test func parsesWholeSecondTimestamps() throws {
        let date = try #require(
            JSONPollerConnector.timestamp(from: "2026-08-19T12:34:56Z"))
        #expect(date.timeIntervalSince1970 == 1_787_142_896)
    }

    @Test func parsesFractionalSecondTimestamps() throws {
        // The shape that used to fall through to `.now`.
        let date = try #require(
            JSONPollerConnector.timestamp(from: "2026-08-19T12:34:56.789Z"))
        #expect(abs(date.timeIntervalSince1970 - 1_787_142_896.789) < 0.001)
    }

    @Test func bothShapesResolveToTheSameSecond() throws {
        let whole = try #require(
            JSONPollerConnector.timestamp(from: "2026-08-19T12:34:56Z"))
        let fractional = try #require(
            JSONPollerConnector.timestamp(from: "2026-08-19T12:34:56.789Z"))
        #expect(fractional > whole)
        #expect(fractional.timeIntervalSince(whole) < 1)
    }

    @Test func parsesNonZuluOffsets() throws {
        let offset = try #require(
            JSONPollerConnector.timestamp(from: "2026-08-19T14:34:56+02:00"))
        let zulu = try #require(
            JSONPollerConnector.timestamp(from: "2026-08-19T12:34:56Z"))
        #expect(offset == zulu)
    }

    @Test func returnsNilForGarbage() {
        // Nil is the contract that lets `fetch()` throw a named reason
        // instead of substituting `.now` (the immortal-item path).
        let garbage = [
            "", "not a date", "19/08/2026", "1786797296",
            "2026-08-19", "2026-13-45T99:99:99Z", "  ",
        ]
        for string in garbage {
            #expect(
                JSONPollerConnector.timestamp(from: string) == nil,
                "expected nil for \(string.debugDescription)")
        }
    }

    @Test func theTwoFormatterOptionSetsAreMutuallyExclusive() {
        // The reason two formatters are needed rather than one. If a future
        // Foundation makes either option set accept both shapes this test
        // fails loudly, and the helper can collapse to one formatter.
        let whole = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        #expect(whole.date(from: "2026-08-19T12:34:56Z") != nil)
        #expect(whole.date(from: "2026-08-19T12:34:56.789Z") == nil)
        #expect(fractional.date(from: "2026-08-19T12:34:56Z") == nil)
        #expect(fractional.date(from: "2026-08-19T12:34:56.789Z") != nil)
    }
}


// MARK: - Claude Code session consolidation (Sources/CLI/ClaudeHook.swift)
//
// Regression coverage for the pile-up this replaced: the `Stop` hook used to
// post `claude-done-<session>-<epoch>`, so every turn ending left a brand-new
// row. A thirty-turn session produced thirty near-identical items and buried
// the only fact that mattered — this session is waiting on you.

struct ClaudeHookConsolidationTests {
    private let session = "3f6c1a2e-0000-4d5e-9f01-abcdefabcdef"

    @Test("Every hook addresses the same session-stable id")
    func oneRowPerSession() {
        let ids = ClaudeHook.Event.allCases.map {
            ClaudeHook.request(for: $0, sessionID: session, cwd: "/tmp/repo").itemID
        }
        #expect(Set(ids).count == 1)
        #expect(ids.first == "claude-\(session)")
    }

    @Test("No hook id carries a timestamp or turn counter")
    func idsAreNotPerTurn() {
        // The bug in one assertion: two invocations of the same hook, at any
        // remove in time, must collide rather than accumulate.
        let first = ClaudeHook.request(for: .stop, sessionID: session, cwd: "/tmp/repo")
        let second = ClaudeHook.request(for: .stop, sessionID: session, cwd: "/tmp/repo")
        #expect(first == second)
        #expect(!first.itemID.contains("done"))
    }

    @Test("Different sessions still get different rows")
    func sessionsStaySeparate() {
        let a = ClaudeHook.request(for: .stop, sessionID: "a", cwd: "/tmp/one").itemID
        let b = ClaudeHook.request(for: .stop, sessionID: "b", cwd: "/tmp/two").itemID
        #expect(a != b)
    }

    @Test("Replying and ending the session both clear the row")
    func repliesClearTheRow() {
        for event in [ClaudeHook.Event.userPromptSubmit, .sessionEnd] {
            let request = ClaudeHook.request(for: event, sessionID: session)
            #expect(request.path == "/clear")
            #expect(request.itemID == "claude-\(session)")
            #expect(request.title == nil)
        }
    }

    @Test("Waiting is high-signal, finishing is not")
    func signalEscalatesWithNeglect() {
        let waiting = ClaudeHook.request(
            for: .notification, sessionID: session, cwd: "/tmp/repo",
            message: "Claude needs your permission to run Bash")
        let finished = ClaudeHook.request(
            for: .stop, sessionID: session, cwd: "/tmp/repo",
            lastAssistantMessage: "Done — the tests pass.")

        #expect(waiting.path == "/notify")
        #expect(waiting.highSignal == true)
        #expect(waiting.kind == "claude_waiting")
        #expect(waiting.title == "Claude needs your permission to run Bash")

        #expect(finished.highSignal == false)
        #expect(finished.kind == "claude_done")
        #expect(finished.title == "Claude finished in repo")
        #expect(finished.body == "Done — the tests pass.")
    }

    @Test("A hook that can't tell where it is still produces an item")
    func missingDirectoryStillPosts() {
        let request = ClaudeHook.request(for: .stop, sessionID: session, cwd: nil)
        #expect(request.title == "Claude finished in unknown")
        #expect(ClaudeHook.projectURL(for: nil) == nil)
        #expect(ClaudeHook.projectURL(for: "/tmp/repo") == "file:///tmp/repo")
    }

    @Test("A notification with no message falls back to a usable title")
    func notificationFallbackTitle() {
        for message in [nil, ""] {
            let request = ClaudeHook.request(
                for: .notification, sessionID: session, cwd: "/tmp/repo", message: message)
            #expect(request.title == "Claude Code needs your input")
        }
    }

    @Test("The snippet is the first non-empty line, capped")
    func snippetIsFirstLine() {
        #expect(ClaudeHook.firstLine(of: "\n\n  hello  \nworld") == "hello")
        #expect(ClaudeHook.firstLine(of: nil) == nil)
        #expect(ClaudeHook.firstLine(of: "\n \n") == nil)
        let long = String(repeating: "x", count: 250)
        let clipped = ClaudeHook.firstLine(of: long)
        #expect(clipped?.count == 201)
        #expect(clipped?.hasSuffix("…") == true)
    }

    @Test("Hook arguments installed by earlier versions keep their spelling")
    func legacyArgumentsUnchanged() {
        // Existing ~/.claude/settings.json entries say `claude-hook
        // notification` and `claude-hook stop`. Renaming either would strand
        // every install made before this version.
        #expect(ClaudeHook.Event.notification.rawValue == "notification")
        #expect(ClaudeHook.Event.stop.rawValue == "stop")
    }
}


// MARK: - Claude Code hook command quoting
// (Sources/App/Connectors/Local/ClaudeCodeIntegration.swift)
//
// Regression coverage for a silent, total failure of the Claude Code
// integration: the app bundle is named "Inbox & Chill.app", and Claude Code
// runs each hook command through a shell. Unquoted, the `&` split the command
// in two — `.../Inbox` backgrounded, then `Chill.app/.../inchill claude-hook
// stop` — so both halves died with "No such file or directory" and no item
// ever reached the queue.

struct ClaudeHookQuotingTests {
    /// Runs `sh -c "printf %s <quoted>"` and returns what the shell resolved
    /// the quoted path to — i.e. exactly the word the hook would execute.
    private func shellExpansion(of path: String) throws -> String {
        let quoted = ClaudeCodeIntegration.shellQuoted(path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("An ampersand in the bundle name survives the shell as one word")
    func ampersandSurvivesShell() throws {
        let path = "/Applications/Inbox & Chill.app/Contents/MacOS/inchill"
        #expect(try shellExpansion(of: path) == path)
    }

    @Test("Spaces, parentheses and quotes all round-trip through the shell")
    func awkwardCharactersRoundTrip() throws {
        for path in [
            "/Users/x/Library/Developer/Xcode/DerivedData/A-b/Build/Products/Debug/Inbox & Chill.app/Contents/MacOS/inchill",
            "/tmp/it's a (weird) $path/inchill",
            "/tmp/semi;colon && echo pwned/inchill",
            "/usr/local/bin/inchill",
        ] {
            #expect(try shellExpansion(of: path) == path)
        }
    }

    @Test("A quoted path cannot smuggle in a second command")
    func noCommandInjection() throws {
        let hostile = "/tmp/x'; touch /tmp/inchill-injection-canary; echo '"
        let expanded = try shellExpansion(of: hostile)
        #expect(expanded == hostile)
        #expect(
            !FileManager.default.fileExists(
                atPath: "/tmp/inchill-injection-canary"))
    }
}

// MARK: - ntfy connector (Sources/App/Connectors/Ntfy/NtfyConnector.swift)

struct NtfyConnectorTests {
    private func frame(_ json: String) throws -> NtfyConnector.Frame {
        try JSONDecoder().decode(NtfyConnector.Frame.self, from: Data(json.utf8))
    }

    // MARK: Frame → RemoteItem

    @Test("A message with a title keeps the body as the snippet")
    func titledMessage() throws {
        let f = try frame(
            #"{"id":"abc123","time":1700000000,"event":"message","topic":"deploys","title":"Deploy finished","message":"web@a1b2c3 is live"}"#)
        let item = try #require(NtfyConnector.item(from: f))
        #expect(item.externalID == "abc123")
        #expect(item.title == "Deploy finished")
        #expect(item.snippet == "web@a1b2c3 is live")
        #expect(item.actorName == "deploys")
        #expect(item.occurredAt == Date(timeIntervalSince1970: 1700000000))
        #expect(item.kind == "ntfy_message")
    }

    @Test("With no title the body becomes the title and is not duplicated")
    func untitledMessage() throws {
        let f = try frame(#"{"id":"x","event":"message","message":"disk almost full"}"#)
        let item = try #require(NtfyConnector.item(from: f))
        #expect(item.title == "disk almost full")
        #expect(item.snippet == nil)
    }

    // MARK: Click-through (Sources/App/Connectors/Ntfy/NtfyConnector.swift)
    //
    // ntfy rows were the only ones in the queue that did nothing on ⏎,
    // because most publishers put the link in the message text rather than
    // in any of the three structured fields that carry one.

    @Test("An explicit click URL wins over everything else")
    func clickOutranksTheRest() throws {
        let f = try frame(
            #"{"id":"x","event":"message","message":"see https://body.example","click":"https://click.example","attachment":{"url":"https://file.example"}}"#)
        #expect(NtfyConnector.link(for: f) == "https://click.example")
    }

    @Test("A view action is used when there is no click URL")
    func viewActionIsUsed() throws {
        let f = try frame(
            #"{"id":"x","event":"message","message":"build failed","actions":[{"action":"broadcast","label":"nope"},{"action":"view","label":"Open","url":"https://ci.example/1"}]}"#)
        #expect(NtfyConnector.link(for: f) == "https://ci.example/1")
    }

    @Test("http and broadcast actions are never opened")
    func nonViewActionsAreIgnored() throws {
        // Clicking a row must not fire a publisher-defined HTTP request.
        let f = try frame(
            #"{"id":"x","event":"message","message":"no link here","actions":[{"action":"http","label":"Delete","url":"https://api.example/delete"}]}"#)
        #expect(NtfyConnector.link(for: f) == nil)
    }

    @Test("A URL in the message body is the last resort, and does get used")
    func bodyURLIsDetected() throws {
        let f = try frame(
            #"{"id":"x","event":"message","title":"PR ready","message":"Review it at https://github.com/a/b/pull/9 please."}"#)
        // The trailing full stop belongs to the sentence, not the URL.
        #expect(
            NtfyConnector.link(for: f) == "https://github.com/a/b/pull/9")
    }

    @Test("The title is read when the body has no URL")
    func titleURLIsDetected() throws {
        let f = try frame(
            #"{"id":"x","event":"message","title":"https://status.example is down","message":"paging you"}"#)
        #expect(NtfyConnector.link(for: f) == "https://status.example")
    }

    @Test("Plain text stays unclickable rather than guessing")
    func plainTextHasNoLink() throws {
        for message in ["disk almost full", "deploy took 3.2s", "v1.2.3 shipped"] {
            #expect(NtfyConnector.firstURL(in: message) == nil)
        }
    }

    @Test("Email addresses and bare hostnames are not opened")
    func onlyHTTPSchemesAreOpened() throws {
        // NSDataDetector matches both; a click that opened a mail composer
        // because the message mentioned an address would be a surprise.
        #expect(NtfyConnector.firstURL(in: "mail someone@example.com") == nil)
        #expect(NtfyConnector.firstURL(in: "ftp://files.example/x") == nil)
    }

    @Test("Priority 4 and 5 are high-signal; 1-3 and the default are not")
    func prioritySignal() throws {
        for (priority, expected) in [(1, false), (2, false), (3, false), (4, true), (5, true)] {
            let f = try frame(#"{"id":"p","event":"message","message":"m","priority":\#(priority)}"#)
            #expect(try #require(NtfyConnector.item(from: f)).highSignal == expected)
        }
        // Absent priority means ntfy's default of 3.
        let noPriority = try frame(#"{"id":"p","event":"message","message":"m"}"#)
        #expect(try #require(NtfyConnector.item(from: noPriority)).highSignal == false)
    }

    @Test("click wins over attachment for the item URL")
    func urlPreference() throws {
        let both = try frame(
            #"{"id":"u","event":"message","message":"m","click":"https://example.com/c","attachment":{"name":"f.png","url":"https://example.com/a"}}"#)
        #expect(try #require(NtfyConnector.item(from: both)).url == "https://example.com/c")

        let attachmentOnly = try frame(
            #"{"id":"u","event":"message","message":"m","attachment":{"url":"https://example.com/a"}}"#)
        #expect(
            try #require(NtfyConnector.item(from: attachmentOnly)).url
                == "https://example.com/a")
    }

    @Test("Control frames and empty messages produce no item")
    func nonMessageFramesAreSkipped() throws {
        for json in [
            #"{"id":"1","event":"open","topic":"t"}"#,
            #"{"id":"2","event":"keepalive","topic":"t"}"#,
            #"{"id":"3","event":"poll_request","topic":"t"}"#,
            // A message with neither title nor body has nothing to show.
            #"{"id":"4","event":"message","topic":"t"}"#,
            #"{"id":"5","event":"message","topic":"t","message":"   "}"#,
        ] {
            #expect(NtfyConnector.item(from: try frame(json)) == nil)
        }
    }

    @Test("A frame with no event field is treated as a message")
    func missingEventIsAMessage() throws {
        let f = try frame(#"{"id":"m","message":"hello"}"#)
        #expect(NtfyConnector.item(from: f) != nil)
    }

    /// Captured verbatim from ntfy.sh on 2026-08-18 (the response body of a
    /// real publish). Guards against drift in the fields we depend on, and
    /// proves unknown keys like `expires` decode harmlessly.
    @Test("A real ntfy.sh payload decodes and maps correctly")
    func realWirePayload() throws {
        let captured = #"""
            {"id":"xcKjTENRpmvh","time":1787069951,"expires":1787113151,"event":"message","topic":"inchill-smoketest","title":"Deploy finished","message":"web@a1b2c3 is live","priority":4,"tags":["rocket"],"click":"https://example.com/build/42"}
            """#
        let item = try #require(NtfyConnector.item(from: try frame(captured)))
        #expect(item.externalID == "xcKjTENRpmvh")
        #expect(item.title == "Deploy finished")
        #expect(item.snippet == "web@a1b2c3 is live")
        #expect(item.url == "https://example.com/build/42")
        #expect(item.actorName == "inchill-smoketest")
        #expect(item.highSignal)  // priority 4
        #expect(item.occurredAt == Date(timeIntervalSince1970: 1787069951))
    }

    // MARK: Socket URL

    @Test("https becomes wss and topics join with commas")
    func socketURLBasics() {
        let url = NtfyConnector.socketURL(
            server: "https://ntfy.sh", topics: "deploys,alerts", since: "12h")
        #expect(url?.absoluteString == "wss://ntfy.sh/deploys,alerts/ws?since=12h")
    }

    @Test("http downgrades to ws for a plain self-hosted instance")
    func socketURLPlainHTTP() {
        let url = NtfyConnector.socketURL(
            server: "http://nas.local:8080", topics: "home", since: nil)
        #expect(url?.absoluteString == "ws://nas.local:8080/home/ws")
    }

    @Test("A base path on the server URL is preserved")
    func socketURLSubpath() {
        for server in ["https://example.com/ntfy", "https://example.com/ntfy/"] {
            let url = NtfyConnector.socketURL(server: server, topics: "t", since: nil)
            #expect(url?.absoluteString == "wss://example.com/ntfy/t/ws")
        }
    }

    @Test("Whitespace and blanks in the topic list are cleaned up")
    func socketURLTopicHygiene() {
        let url = NtfyConnector.socketURL(
            server: "https://ntfy.sh", topics: " a , ,b ,", since: nil)
        #expect(url?.absoluteString == "wss://ntfy.sh/a,b/ws")
    }

    @Test("No usable topics, or a non-HTTP scheme, yields no URL")
    func socketURLRejections() {
        #expect(NtfyConnector.socketURL(server: "https://ntfy.sh", topics: "", since: nil) == nil)
        #expect(NtfyConnector.socketURL(server: "https://ntfy.sh", topics: " , ", since: nil) == nil)
        #expect(NtfyConnector.socketURL(server: "ftp://ntfy.sh", topics: "t", since: nil) == nil)
    }
}

// MARK: - Journal export (Sources/App/Journal/JournalWriter.swift)

struct JournalWriterTests {
    /// 2026-08-18, 12:00 **UTC**.
    ///
    /// It was 16:00 UTC — noon in US Eastern, where it was written — until CI
    /// ran the suite on a UTC machine for the first time on 2026-08-21 and two
    /// tests failed. Midday UTC keeps the calendar date the same everywhere
    /// from UTC-11 to UTC+11, so the `{{YYYY}}-{{MM}}-{{DD}}` path assertions
    /// below hold wherever the suite runs. (UTC+12 lands on midnight of the
    /// 19th; nothing here runs in Auckland yet.)
    private let noon = Date(timeIntervalSince1970: 1787054400)

    /// `JournalWriter.line` renders the time in the machine's own time zone,
    /// which is right for a journal — an entry made at noon should read 12:00
    /// in the file, not whatever that was in UTC. So the expected time cannot
    /// be a string literal: the same instant is a different wall clock in
    /// every zone, and hardcoding one made these tests pass on exactly one
    /// machine. Derive the field the way the code does, and assert its
    /// *shape* separately in `lineTimeIsMachineStable`.
    private var noonTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: noon)
    }

    private func entry(
        action: JournalAction = .done, sourceName: String = "Linear",
        title: String = "Fix the flaky sync test",
        url: String? = "https://linear.app/x/ISS-1", detail: String? = nil
    ) -> JournalEntry {
        JournalEntry(
            at: noon, action: action, sourceName: sourceName, title: title,
            url: url, detail: detail)
    }

    // MARK: Path templating

    @Test("Date tokens are replaced and a leading tilde expands")
    func pathTokens() throws {
        let url = try #require(
            JournalWriter.resolvePath(
                template: "~/Vault/daily/{{YYYY}}-{{MM}}-{{DD}}.md", date: noon))
        #expect(url.path.hasSuffix("/Vault/daily/2026-08-18.md"))
        #expect(url.path.hasPrefix("/"))
        #expect(!url.path.contains("~"))
    }

    @Test("Months and days are zero-padded")
    func pathZeroPadding() throws {
        // 2026-01-05
        let january = Date(timeIntervalSince1970: 1767625200)
        let url = try #require(
            JournalWriter.resolvePath(
                template: "/tmp/{{YYYY}}/{{MM}}/{{DD}}.md", date: january))
        #expect(url.path == "/tmp/2026/01/05.md")
    }

    @Test("A tilde inside the path is a literal directory name")
    func pathInnerTildeIsLiteral() throws {
        let url = try #require(
            JournalWriter.resolvePath(template: "/tmp/a~b/note.md", date: noon))
        #expect(url.path == "/tmp/a~b/note.md")
    }

    /// Obsidian's iCloud vault path is `iCloud~md~obsidian` — tildes in the
    /// middle of the path, which must survive leading-tilde expansion.
    @Test("Interior tildes survive when the path also starts with ~")
    func pathObsidianICloudVault() throws {
        let url = try #require(
            JournalWriter.resolvePath(
                template:
                    "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brain/daily-notes/{{YYYY}}-{{MM}}-{{DD}}.md",
                date: noon))
        #expect(url.path.contains("/iCloud~md~obsidian/"))
        #expect(url.path.hasSuffix("/Brain/daily-notes/2026-08-18.md"))
        #expect(!url.path.hasPrefix("~"))
    }

    @Test("Blank or relative templates resolve to nothing")
    func pathRejections() {
        #expect(JournalWriter.resolvePath(template: "", date: noon) == nil)
        #expect(JournalWriter.resolvePath(template: "   ", date: noon) == nil)
        #expect(JournalWriter.resolvePath(template: "notes/today.md", date: noon) == nil)
    }

    // MARK: Line rendering

    @Test("A full entry renders every field in order")
    func lineFull() {
        let line = JournalWriter.line(for: entry(detail: "waited 11m"))
        #expect(
            line
                == "- \(noonTime) · **done** · Linear · [Fix the flaky sync test](https://linear.app/x/ISS-1) · waited 11m"
        )
    }

    /// The field order test above derives the time, so this is what still
    /// pins the format itself: `HH:mm`, zero-padded, 24-hour, no locale
    /// leaking in. A journal that reads `09:41` for one user and `9:41 AM`
    /// for another is a journal nothing can parse.
    @Test("The time field is zero-padded 24-hour, whatever the machine's locale")
    func lineTimeIsMachineStable() {
        let line = JournalWriter.line(for: entry())
        // Past the "- " bullet, the time is the first field.
        let time = String(line.dropFirst(2).prefix(5))
        let parts = time.components(separatedBy: ":")
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { part in
            part.count == 2 && part.allSatisfy { $0.isNumber }
        })
    }

    @Test("With no URL the title stays plain text rather than a broken link")
    func lineWithoutURL() {
        let line = JournalWriter.line(for: entry(url: nil))
        #expect(line == "- \(noonTime) · **done** · Linear · Fix the flaky sync test")
        #expect(!line.contains("]("))

        // An all-whitespace URL is the same case.
        #expect(!JournalWriter.line(for: entry(url: "   ")).contains("]("))
    }

    @Test("Newlines in a title can't split one event across lines")
    func lineFlattensMultilineTitles() {
        let line = JournalWriter.line(
            for: entry(title: "first line\nsecond line\n\nthird"))
        #expect(line.components(separatedBy: "\n").count == 1)
        #expect(line.contains("first line second line third"))
    }

    @Test("Brackets in a title can't break out of the markdown link")
    func lineEscapesBrackets() {
        let line = JournalWriter.line(for: entry(title: "[URGENT] ship it"))
        #expect(line.contains("[(URGENT) ship it]("))
    }

    @Test("An empty source name degrades to a placeholder, not an empty field")
    func lineEmptySource() {
        #expect(JournalWriter.line(for: entry(sourceName: "")).contains("· unknown ·"))
    }

    // MARK: Dwell time

    @Test("Waited renders minutes, hours and days; sub-minute is omitted")
    func waitedFormatting() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(JournalWriter.waited(from: start, to: start.addingTimeInterval(30)) == nil)
        #expect(JournalWriter.waited(from: start, to: start.addingTimeInterval(660)) == "waited 11m")
        #expect(
            JournalWriter.waited(from: start, to: start.addingTimeInterval(3600 * 3 + 720))
                == "waited 3h 12m")
        #expect(
            JournalWriter.waited(from: start, to: start.addingTimeInterval(86400 * 2 + 3600 * 4))
                == "waited 2d 4h")
    }

    // MARK: Section insertion

    @Test("An empty file gets the heading and the entry")
    func insertIntoEmptyFile() {
        let out = JournalWriter.insert(
            line: "- a", into: "", heading: "## Inbox & Chill")
        #expect(out == "## Inbox & Chill\n\n- a\n")
    }

    @Test("An existing section gains the entry after the entries already there")
    func insertAppendsWithinSection() {
        let existing = "# Daily\n\n## Inbox & Chill\n\n- first\n- second\n"
        let out = JournalWriter.insert(
            line: "- third", into: existing, heading: "## Inbox & Chill")
        #expect(out.contains("- first\n- second\n- third"))
    }

    @Test("The entry lands inside our section, never in the next one")
    func insertRespectsFollowingHeading() {
        let existing = """
            ## Inbox & Chill

            - first

            ## Notes

            some other content
            """
        let out = JournalWriter.insert(
            line: "- second", into: existing, heading: "## Inbox & Chill")
        let lines = out.components(separatedBy: "\n")
        let inserted = try! #require(lines.firstIndex(of: "- second"))
        let notes = try! #require(lines.firstIndex(of: "## Notes"))
        #expect(inserted < notes)
        // And it must sit right after the existing entry, not after the blank.
        #expect(lines[inserted - 1] == "- first")
    }

    @Test("A missing heading is created at the end without disturbing content")
    func insertCreatesMissingSection() {
        let existing = "# Daily 2026-08-18\n\nWoke up late.\n"
        let out = JournalWriter.insert(
            line: "- a", into: existing, heading: "## Inbox & Chill")
        #expect(out == "# Daily 2026-08-18\n\nWoke up late.\n\n## Inbox & Chill\n\n- a\n")
    }

    @Test("Trailing blank lines don't accumulate when the section is created")
    func insertNormalizesTrailingBlanks() {
        let out = JournalWriter.insert(
            line: "- a", into: "content\n\n\n\n", heading: "## H")
        #expect(out == "content\n\n## H\n\n- a\n")
    }

    @Test("An empty heading setting still produces a valid section")
    func insertBlankHeadingFallsBack() {
        let out = JournalWriter.insert(line: "- a", into: "", heading: "   ")
        #expect(out.contains("## Journal"))
        #expect(out.contains("- a"))
    }

    @Test("Repeated inserts stay chronological and never duplicate a heading")
    func insertIsRepeatable() {
        var content = "# Daily\n"
        for index in 1...4 {
            content = JournalWriter.insert(
                line: "- entry \(index)", into: content, heading: "## Inbox & Chill")
        }
        #expect(content.components(separatedBy: "## Inbox & Chill").count - 1 == 1)
        let body = content.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        #expect(body == ["- entry 1", "- entry 2", "- entry 3", "- entry 4"])
    }
}

// MARK: - Journal permission diagnostics

struct JournalPermissionMessageTests {
    private func permissionError() -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }

    @Test("An iCloud-container path explains Full Disk Access")
    func iCloudContainerHint() {
        let url = URL(
            fileURLWithPath:
                "/Users/x/Library/Mobile Documents/iCloud~md~obsidian/Documents/Brain/daily-notes/2026-08-18.md"
        )
        let message = (JournalWriter.explain(permissionError(), url: url) as? LocalizedError)?
            .errorDescription ?? ""
        #expect(message.contains("Full Disk Access"))
        #expect(message.contains("another app's iCloud container"))
        #expect(message.contains(url.path))
    }

    @Test("A plain protected path points at Files and Folders instead")
    func filesAndFoldersHint() {
        let url = URL(fileURLWithPath: "/Users/x/Documents/vault/2026-08-18.md")
        let message = (JournalWriter.explain(permissionError(), url: url) as? LocalizedError)?
            .errorDescription ?? ""
        #expect(message.contains("Files and Folders"))
        #expect(!message.contains("iCloud"))
    }

    @Test("A non-permission error is passed through untouched")
    func nonPermissionErrorUnchanged() {
        let original = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        let out = JournalWriter.explain(original, url: URL(fileURLWithPath: "/tmp/a.md"))
        #expect((out as NSError).code == NSFileWriteOutOfSpaceError)
    }
}

// MARK: - Toggle-style connector fields (participating, etc.)

/// Setup instructions live in the catalog so the app can show them; nobody
/// reads a docs file while staring at an empty token field. These pin the
/// two properties that decay quietly: a new connector shipping with no
/// instructions at all, and steps growing into paragraphs.
struct ConnectorSetupStepsTests {
    private var withSecrets: [ConnectorKindDescriptor] {
        ConnectorCatalog.all.filter { $0.fields.contains(where: \.isSecret) }
    }

    @Test("Every source that asks for a credential says how to get one")
    func credentialSourcesExplainThemselves() {
        for descriptor in withSecrets {
            #expect(
                !descriptor.setupSteps.isEmpty,
                "\(descriptor.displayName) asks for a secret with no setup steps")
        }
    }

    @Test("Steps stay short enough to read at a glance")
    func stepsAreBrief() {
        // The brief is literally "quite brief and clear". A step that has
        // grown past a couple of lines belongs in authNote or the docs.
        for descriptor in ConnectorCatalog.all {
            for step in descriptor.setupSteps {
                #expect(
                    step.count <= 200,
                    "\(descriptor.displayName): step is \(step.count) chars")
            }
            #expect(descriptor.setupSteps.count <= 6)
        }
    }

    @Test("A setup link is a real https URL to the provider")
    func setupLinksResolve() {
        for descriptor in ConnectorCatalog.all where !descriptor.setupURL.isEmpty {
            let url = URL(string: descriptor.setupURL)
            #expect(url?.scheme == "https", "\(descriptor.displayName)")
            #expect(url?.host()?.isEmpty == false, "\(descriptor.displayName)")
        }
    }

    @Test("The Slack manifest still grants what the connector depends on")
    func slackManifestCoversTheFeatures() {
        let manifest = ConnectorCatalog.slackAppManifest
        // Each of these is load-bearing; the comment is what breaks without it.
        let required = [
            "im:history",       // DM unreads
            "channels:history", // channel mentions
            "reactions:read",   // emoji-save gesture
            "reactions:write",  // un-save removes the reaction
            "users:read",       // display names instead of raw ids
            "search:read",      // Keyword Watch — the only path into a
                                // channel you are not in
        ]
        for scope in required {
            #expect(manifest.contains(scope), "manifest is missing \(scope)")
        }
        #expect(manifest.contains("socket_mode_enabled: true"))
        // RTM-era event types Slack's validator rejects outright.
        for rejected in ["im_marked", "channel_marked", "mpim_marked"] {
            #expect(!manifest.contains(rejected))
        }
    }

    @Test("Slack offers the manifest to copy; nothing else needs a payload")
    func onlySlackCarriesAPayload() {
        for descriptor in ConnectorCatalog.all {
            if descriptor.id == "slack" {
                #expect(descriptor.setupPayload?.text.isEmpty == false)
            } else {
                #expect(descriptor.setupPayload == nil)
            }
        }
    }
}

struct ConnectorToggleFieldTests {
    private var participating: ConnectorKindDescriptor.Field {
        ConnectorCatalog.descriptor(for: "github")!
            .fields.first { $0.key == "participating" }!
    }

    @Test("GitHub exposes participating as a toggle that defaults on")
    func participatingFieldShape() {
        let field = participating
        #expect(field.isToggle)
        #expect(field.defaultOn)
        #expect(!field.isSecret)
    }

    /// An absent key means the user has never touched the setting, which must
    /// resolve to the descriptor's default rather than to `false` — otherwise
    /// adding a toggle silently flips behaviour for every existing source.
    @Test("An unwritten toggle resolves to its default, not false")
    func unwrittenToggleUsesDefault() {
        #expect(participating.boolValue(in: [:]))
        #expect(participating.boolValue(in: ["other": "false"]))
    }

    @Test("An explicit value always wins over the default")
    func explicitValueWins() {
        #expect(!participating.boolValue(in: ["participating": "false"]))
        #expect(participating.boolValue(in: ["participating": "true"]))
    }

    /// An empty string is what the editor sheet can persist for a field the
    /// user never touched, so it must agree with what the checkbox displays —
    /// the default — rather than reading as off.
    @Test("Empty reads as the default; other unparseable values read as off")
    func emptyMatchesTheCheckbox() {
        #expect(participating.boolValue(in: ["participating": ""]))
        #expect(!participating.boolValue(in: ["participating": "yes"]))
    }
}

// MARK: - ntfy authentication

struct NtfyAuthTests {
    @Test("No credentials means no header — an unprotected topic needs none")
    func anonymous() {
        #expect(NtfyConnector.authorizationHeader(token: nil, username: nil, password: nil) == nil)
        #expect(NtfyConnector.authorizationHeader(token: "", username: "", password: "") == nil)
    }

    @Test("A token becomes a bearer header")
    func bearerToken() {
        #expect(
            NtfyConnector.authorizationHeader(
                token: "tk_example_not_a_real_token", username: nil, password: nil)
                == "Bearer tk_example_not_a_real_token")
    }

    @Test("Username and password become base64 basic auth")
    func basicAuth() {
        let header = NtfyConnector.authorizationHeader(
            token: nil, username: "phil", password: "mypass")
        // base64("phil:mypass")
        #expect(header == "Basic cGhpbDpteXBhc3M=")
    }

    @Test("A token wins over username and password")
    func tokenTakesPrecedence() {
        let header = NtfyConnector.authorizationHeader(
            token: "tk_abc", username: "phil", password: "mypass")
        #expect(header == "Bearer tk_abc")
    }

    /// Half a credential would only ever 401, and sending it would make the
    /// failure look like a server problem rather than a filled-in-wrong field.
    @Test("Half a basic credential sends nothing at all")
    func incompleteBasicAuthIsIgnored() {
        #expect(
            NtfyConnector.authorizationHeader(token: nil, username: "phil", password: nil) == nil)
        #expect(
            NtfyConnector.authorizationHeader(token: nil, username: "phil", password: "") == nil)
        #expect(
            NtfyConnector.authorizationHeader(token: nil, username: nil, password: "mypass") == nil)
    }

    @Test("Surrounding whitespace in a pasted credential is trimmed")
    func trimsPastedWhitespace() {
        #expect(
            NtfyConnector.authorizationHeader(
                token: "  tk_abc\n", username: nil, password: nil) == "Bearer tk_abc")
        #expect(
            NtfyConnector.authorizationHeader(
                token: "   ", username: " phil ", password: "mypass")
                == "Basic cGhpbDpteXBhc3M=")
    }

    @Test("A password's own characters are never trimmed")
    func passwordIsTakenVerbatim() {
        // Leading/trailing spaces can be legitimate password characters, so
        // unlike the username they must survive intact.
        let header = NtfyConnector.authorizationHeader(
            token: nil, username: "phil", password: " pass ")
        #expect(header == "Basic " + Data("phil: pass ".utf8).base64EncodedString())
    }
}

// MARK: - ntfy failure classification

struct NtfyFailureStatusTests {
    private func message(_ status: ConnectorStatus) -> String? {
        if case .error(let text) = status { return text }
        return nil
    }

    /// The one that matters: ntfy 401s even on a topic that works anonymously
    /// when it's handed wrong credentials. Reporting that as "connecting"
    /// would leave a typo'd password silently never delivering.
    @Test("401 is a visible error naming the public-topic trap")
    func unauthorizedIsAnError() throws {
        let text = try #require(message(NtfyConnector.status(forHTTPStatus: 401)))
        #expect(text.contains("401"))
        #expect(text.lowercased().contains("public"))
    }

    @Test("403 and 404 are errors too, each pointing somewhere useful")
    func forbiddenAndNotFound() throws {
        #expect(try #require(message(NtfyConnector.status(forHTTPStatus: 403))).contains("403"))
        let notFound = try #require(message(NtfyConnector.status(forHTTPStatus: 404)))
        #expect(notFound.contains("server URL"))
    }

    @Test("Transient and unknown failures read as reconnecting, not broken")
    func transientFailuresReconnect() {
        for code in [nil, 500, 502, 503, 429] as [Int?] {
            #expect(NtfyConnector.status(forHTTPStatus: code) == .connecting)
        }
    }
}

// MARK: - Slack user-token validation

struct SlackTokenValidationTests {
    @Test("A plain user token is accepted")
    func validUserToken() {
        #expect(SlackConnector.userTokenProblem("xoxp-example-user-token") == nil)
        // Pasted with stray whitespace is still fine.
        #expect(SlackConnector.userTokenProblem("  xoxp-example\n") == nil)
    }

    /// The one Brandon actually hit: `xoxe.xoxp-` is an app *configuration*
    /// token — Manifest API only, 12-hour life, useless for the Web API.
    @Test("An xoxe. configuration token is rejected with the reason")
    func configurationTokenRejected() throws {
        let problem = try #require(SlackConnector.userTokenProblem("xoxe.xoxp-example-config-token"))
        #expect(problem.contains("configuration token"))
        #expect(problem.contains("OAuth & Permissions"))
        #expect(problem.contains("12 hours"))
    }

    @Test("Bot and app-level tokens are named for what they are")
    func wrongTokenKinds() throws {
        #expect(try #require(SlackConnector.userTokenProblem("xoxb-example-bot-token")).contains("bot token"))
        let appLevel = try #require(SlackConnector.userTokenProblem("xapp-example-app-token"))
        #expect(appLevel.contains("App-Level Token field"))
    }

    @Test("Anything else is flagged rather than sent")
    func unrecognisedToken() throws {
        #expect(SlackConnector.userTokenProblem("") == "No user token configured.")
        #expect(try #require(SlackConnector.userTokenProblem("hunter2")).contains("xoxp-"))
    }
}

// MARK: - Banner permission wording (Sources/App/AppState.swift)

/// Banners are the one feature whose failure the app can't observe: macOS
/// takes the posting call and drops it. Every path out of the permission
/// check therefore has to produce something the user can read.
struct BannerAuthorizationTests {
    @Test func authorizedStatusesGrant() {
        #expect(
            BannerAuthorization.settledOutcome(status: .authorized) == .granted)
        #expect(
            BannerAuthorization.settledOutcome(status: .provisional) == .granted)
    }

    /// `.notDetermined` is the only status the caller still gets a say in.
    @Test func notDeterminedIsUnsettled() {
        #expect(BannerAuthorization.settledOutcome(status: .notDetermined) == nil)
    }

    @Test func deniedExplainsItselfAndNamesTheFix() {
        let outcome = BannerAuthorization.settledOutcome(status: .denied)
        #expect(outcome == .blocked(BannerAuthorization.deniedMessage))
        #expect(outcome?.message?.contains("System Settings") == true)
    }

    @Test func grantedCarriesNoComplaint() {
        let outcome = BannerAuthorization.requestOutcome(granted: true, error: nil)
        #expect(outcome == .granted)
        #expect(outcome.message == nil)
    }

    /// The original bug: a refused request returned `false` and posted
    /// nothing, leaving no banner and no reason for its absence.
    @Test func refusedRequestNeverGoesSilent() {
        let outcome = BannerAuthorization.requestOutcome(granted: false, error: nil)
        #expect(outcome.message != nil)
    }

    /// A thrown request error is the diagnostic — it must reach the user
    /// verbatim, not be flattened into a generic "couldn't show banners".
    @Test func thrownRequestErrorSurvivesIntoTheMessage() {
        let outcome = BannerAuthorization.requestOutcome(
            granted: false,
            error: "Notifications are not allowed for this application")
        #expect(
            outcome.message?.contains("not allowed for this application") == true)
    }

    /// Permission granted still isn't a banner delivered.
    @Test func postFailureIsReportedToo() {
        #expect(BannerAuthorization.postFailure("boom").message?.contains("boom") == true)
    }

    @Test func settingsDeepLinkTargetsNotifications() {
        #expect(
            BannerAuthorization.systemSettingsURL.absoluteString
                .contains("Notifications"))
    }
}
