import XCTest
@testable import Pulse

final class RestaurantHomeTests: XCTestCase {
    private func status(_ printers: String) throws -> RestaurantStatus {
        let json = #"{"ok":true,"date":"2026-10-16","tables":{"open_count":5},"diners":{"current_guests":18,"today_guests":73},"printers":"# + printers + "}"
        return try RestaurantStatus.decode(Data(json.utf8))
    }
    func testReadsDistinctCurrentAndDailyCounts() throws {
        let result = try status(#"{"agent_online":true,"offline_count":0,"unknown_count":0,"has_offline":false,"items":[{"state":"online"}]}"#)
        XCTAssertEqual(result.tables?.openCount, 5)
        XCTAssertEqual(result.diners?.currentGuests, 18)
        XCTAssertEqual(result.diners?.todayGuests, 73)
        XCTAssertEqual(result.printers?.overall, .online)
    }
    func testPrinterOfflineAndUnknownAreNotOnline() throws {
        XCTAssertEqual(try status(#"{"agent_online":false,"offline_count":0,"unknown_count":0,"has_offline":false}"#).printers?.overall, .offline)
        XCTAssertEqual(try status(#"{"agent_online":true,"offline_count":1,"unknown_count":0,"has_offline":true}"#).printers?.overall, .offline)
        XCTAssertEqual(try status(#"{"agent_online":true,"offline_count":0,"unknown_count":1,"has_offline":null}"#).printers?.overall, .unknown)
        XCTAssertEqual(try status(#"{}"#).printers?.overall, .unknown)
        XCTAssertEqual(try status(#"{"agent_online":true,"items":[{"state":"disabled"}]}"#).printers?.overall, .notConfigured)
    }
    func testMissingHistoryDaysRemainUnknown() {
        let records = [RestaurantGuestDay(date: "2026-10-16", guests: 73), RestaurantGuestDay(date: "2026-10-14", guests: 0)]
        let week = RestaurantWeek.filled(records, ending: "2026-10-16")
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.first?.date, "2026-10-10")
        XCTAssertNil(week[0].guests)
        XCTAssertEqual(week[4].guests, 0)
        XCTAssertNil(week[5].guests)
        XCTAssertEqual(week[6].guests, 73)
    }
    func testExistingRestaurantConfigMigratesWithoutLosingIdentity() throws {
        let id = UUID()
        let old = #"{"id":""# + id.uuidString + #"","name":"Existing","baseURL":"https://example.com/r/second"}"#
        let decoded = try JSONDecoder().decode(RestaurantConnection.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "Existing")
        XCTAssertTrue(decoded.showOnHome)
    }
    func testInvalidDateDoesNotInventAWeek() {
        XCTAssertTrue(RestaurantWeek.dates(ending: "invalid").isEmpty)
        XCTAssertTrue(RestaurantWeek.dates(ending: "2026-02-30").isEmpty)
    }
    func testHistoryUsesInclusiveSevenDayDateRange() throws {
        let query = try RestaurantWeek.historyQuery(ending: "2026-10-17")
        XCTAssertEqual(query.map(\.name), ["start_date", "end_date"])
        XCTAssertEqual(query.map(\.value), ["2026-10-11", "2026-10-17"])
        let monthBoundary = try RestaurantWeek.historyQuery(ending: "2026-11-02")
        XCTAssertEqual(monthBoundary.map(\.value), ["2026-10-27", "2026-11-02"])
    }
    func testHistoryReadsItemsGuestsAndMissingCounts() throws {
        let json = #"{"ok":true,"restaurant":"Third restaurant","updated_at":1792231200,"timezone":"Europe/Madrid","start_date":"2026-10-11","end_date":"2026-10-17","total_guests":35,"total_opened_rounds":10,"total_rounds_without_guests":2,"items":[{"date":"2026-10-11","guests":35,"opened_rounds":8,"rounds_without_guests":2},{"date":"2026-10-12","guests":0,"opened_rounds":0,"rounds_without_guests":0}]}"#
        let decoded = try JSONDecoder().decode(RestaurantGuestHistory.self, from: Data(json.utf8))
        let week = try decoded.week(ending: "2026-10-17")
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week[0].guests, 35)
        XCTAssertEqual(week[0].missing, 2)
        XCTAssertEqual(week[0].openedRounds, 8)
        XCTAssertEqual(week[1].guests, 0)
        XCTAssertEqual(week[1].openedRounds, 0)
        XCTAssertNil(week[2].guests)
        XCTAssertNil(week[2].openedRounds)
    }
    func testHistoryRejectsWrongDateRangeAndInvalidRecords() throws {
        let json = #"{"ok":true,"timezone":"Europe/Madrid","start_date":"2026-10-11","end_date":"2026-10-17","items":[]}"#
        let decoded = try JSONDecoder().decode(RestaurantGuestHistory.self, from: Data(json.utf8))
        XCTAssertThrowsError(try decoded.week(ending: "2026-10-18"))
        let negative = json.replacingOccurrences(of: "\"items\":[]", with: "\"items\":[{\"date\":\"2026-10-11\",\"guests\":-1}]")
        let invalid = try JSONDecoder().decode(RestaurantGuestHistory.self, from: Data(negative.utf8))
        XCTAssertThrowsError(try invalid.week(ending: "2026-10-17"))
    }
    func testSavedHistoryKeepsUnregisteredGuestWarning() throws {
        let cached = RestaurantHistoryCache(days: [RestaurantGuestDay(date: "2026-10-17", guests: 21, missing: 2, openedRounds: 8)], timezone: "Europe/Madrid", savedAt: Date(timeIntervalSince1970: 1792231200))
        let data = try JSONEncoder().encode(cached)
        let restored = try JSONDecoder().decode(RestaurantHistoryCache.self, from: data)
        XCTAssertEqual(restored.days.first?.guests, 21)
        XCTAssertEqual(restored.days.first?.missing, 2)
        XCTAssertEqual(restored.days.first?.openedRounds, 8)
        XCTAssertEqual(restored.timezone, "Europe/Madrid")
    }
    @MainActor
    func testTodayOpenedUsesTodaysRoundsRatherThanCurrentOpenTables() throws {
        let monitor = RestaurantMonitor()
        monitor.status = try status(#"{}"#)
        monitor.history = [RestaurantGuestDay(date: "2026-10-15", guests: 100, openedRounds: 35), RestaurantGuestDay(date: "2026-10-16", guests: 73, openedRounds: 22)]
        XCTAssertEqual(monitor.todayOpenedCount, 22)
        XCTAssertEqual(monitor.status?.tables?.openCount, 5)
        monitor.history = [RestaurantGuestDay(date: "2026-10-15", guests: 100, openedRounds: 35)]
        XCTAssertNil(monitor.todayOpenedCount)
    }
}
