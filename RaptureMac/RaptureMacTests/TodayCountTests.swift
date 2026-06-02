import XCTest
@testable import Rapture

final class TodayCountTests: XCTestCase {

    // Pin to UTC so the ISO-8601 fixtures land on the calendar day the test expects,
    // regardless of where CI / dev machines happen to be.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ string: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)!
    }

    // MARK: - incrementing()

    func testIncrementingFromNilDateStartsAtOne() {
        let (date, count) = PersistedState.incrementing(
            currentDate: nil,
            currentCount: 0,
            at: date("2026-05-19T14:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(count, 1)
        XCTAssertEqual(date, self.date("2026-05-19T14:00:00Z"))
    }

    func testIncrementingSameDayBumpsCount() {
        let (_, count) = PersistedState.incrementing(
            currentDate: date("2026-05-19T09:00:00Z"),
            currentCount: 5,
            at: date("2026-05-19T15:00:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(count, 6)
    }

    func testIncrementingNewDayResetsToOne() {
        let (date, count) = PersistedState.incrementing(
            currentDate: self.date("2026-05-19T23:55:00Z"),
            currentCount: 99,
            at: self.date("2026-05-20T00:30:00Z"),
            calendar: calendar
        )
        XCTAssertEqual(count, 1)
        XCTAssertEqual(date, self.date("2026-05-20T00:30:00Z"))
    }

    // MARK: - displayedTodayCount()

    func testDisplayedCountReturnsZeroWhenStaleDay() {
        let state = PersistedState(
            todayCount: 7,
            todayDate: date("2026-05-18T12:00:00Z"),
            lastCaptureAt: date("2026-05-18T12:00:00Z")
        )
        XCTAssertEqual(
            state.displayedTodayCount(at: date("2026-05-19T09:00:00Z"), calendar: calendar),
            0
        )
    }

    func testDisplayedCountReturnsCountWhenSameDay() {
        let state = PersistedState(
            todayCount: 7,
            todayDate: date("2026-05-19T05:00:00Z"),
            lastCaptureAt: date("2026-05-19T05:00:00Z")
        )
        XCTAssertEqual(
            state.displayedTodayCount(at: date("2026-05-19T22:00:00Z"), calendar: calendar),
            7
        )
    }

    func testDisplayedCountReturnsZeroWhenDateNil() {
        let state = PersistedState()
        XCTAssertEqual(state.displayedTodayCount(at: Date(), calendar: calendar), 0)
    }
}
