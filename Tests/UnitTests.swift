import AppKit
import Foundation
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
        let config = SourceConfig(kind: "campsite", displayName: "Campsite")
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
    private let noon = Date(timeIntervalSince1970: 1787068800)  // 2026-08-18

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
                == "- 12:00 · **done** · Linear · [Fix the flaky sync test](https://linear.app/x/ISS-1) · waited 11m"
        )
    }

    @Test("With no URL the title stays plain text rather than a broken link")
    func lineWithoutURL() {
        let line = JournalWriter.line(for: entry(url: nil))
        #expect(line == "- 12:00 · **done** · Linear · Fix the flaky sync test")
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
                token: "tk_3gd7d2yftt4b8ixyfe9mnmro88o76", username: nil, password: nil)
                == "Bearer tk_3gd7d2yftt4b8ixyfe9mnmro88o76")
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
        #expect(SlackConnector.userTokenProblem("xoxp-123-456-abc") == nil)
        // Pasted with stray whitespace is still fine.
        #expect(SlackConnector.userTokenProblem("  xoxp-123\n") == nil)
    }

    /// The one Brandon actually hit: `xoxe.xoxp-` is an app *configuration*
    /// token — Manifest API only, 12-hour life, useless for the Web API.
    @Test("An xoxe. configuration token is rejected with the reason")
    func configurationTokenRejected() throws {
        let problem = try #require(SlackConnector.userTokenProblem("xoxe.xoxp-1-abc"))
        #expect(problem.contains("configuration token"))
        #expect(problem.contains("OAuth & Permissions"))
        #expect(problem.contains("12 hours"))
    }

    @Test("Bot and app-level tokens are named for what they are")
    func wrongTokenKinds() throws {
        #expect(try #require(SlackConnector.userTokenProblem("xoxb-1-2-3")).contains("bot token"))
        let appLevel = try #require(SlackConnector.userTokenProblem("xapp-1-A-2-3"))
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
