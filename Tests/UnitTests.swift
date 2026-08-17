import Foundation
import SwiftData
import Testing

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
