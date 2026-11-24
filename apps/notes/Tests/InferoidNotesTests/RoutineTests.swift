import XCTest
@testable import InferoidNotesKit

final class RoutineScheduleTests: XCTestCase {
    func testDailyAndWeekdaySchedulesUseLocalCalendarTime() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 7, minute: 59))) // Monday
        let daily = try XCTUnwrap(RoutineScheduleCalculator.nextRun(after: start, schedule: .everyDay, hour: 8, minute: 0, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: daily), DateComponents(day: 23, hour: 8, minute: 0))
        let weekday = try XCTUnwrap(RoutineScheduleCalculator.nextRun(after: daily, schedule: .weekdays, hour: 8, minute: 0, calendar: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: weekday), 3) // Tuesday, because the Monday slot was just consumed.
    }

    func testCatchUpReturnsOnePersistedOccurrence() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let due = now.addingTimeInterval(-60)
        XCTAssertEqual(RoutineScheduleCalculator.catchUpOccurrence(nextRun: due, at: now), due)
        XCTAssertNil(RoutineScheduleCalculator.catchUpOccurrence(nextRun: nil, at: now))
    }
}

@MainActor
final class RoutineStoreTests: XCTestCase {
    func testOldWeeklyReflectionDataDecodesWithNewCheckbackField() throws {
        let old = #"{"weekStart":"2026-11-16T00:00:00Z","people":["A"],"promisesMade":[],"promisesKept":[],"promisesOverdue":[],"itemsAdded":[],"generatedAt":"2026-11-23T00:00:00Z"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reflection = try decoder.decode(WeeklyReflection.self, from: Data(old.utf8))
        XCTAssertEqual(reflection.people, ["A"])
        XCTAssertEqual(reflection.decisionCheckbacks, [])
    }

    func testDefaultsAreCreatedOnceAndStorageRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inferoid-routines-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RoutineStore(root: root)
        XCTAssertEqual(Set(first.routines.map(\.name)), Set(["Morning brief", "Weekly reflection", "Keep in touch"]))
        var custom = Routine(name: "Local test", prompt: "Read the Brain", schedule: .monthly(day: 31), hour: 10, minute: 15,
                             scope: .libraryOnly, delivery: .journalOnly)
        first.save(custom)
        let second = RoutineStore(root: root)
        custom = try XCTUnwrap(second.routines.first { $0.name == "Local test" })
        XCTAssertEqual(custom.scope, .libraryOnly)
        XCTAssertEqual(custom.delivery, .journalOnly)
        XCTAssertEqual(custom.schedule, .monthly(day: 31))
    }
}
