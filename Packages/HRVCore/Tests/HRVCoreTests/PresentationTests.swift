import Foundation
import XCTest
@testable import HRVCore

final class PresentationTests: XCTestCase {
    func testIndexLevelBandsFollowTheRangeBars() {
        // Regeneration: high is good
        XCTAssertEqual(IndexLevel(value: 5.0, direction: .higherIsBetter), .normal)
        XCTAssertEqual(IndexLevel(value: 4.0, direction: .higherIsBetter), .normal)
        XCTAssertEqual(IndexLevel(value: 6.0, direction: .higherIsBetter), .normal)
        XCTAssertEqual(IndexLevel(value: 6.1, direction: .higherIsBetter), .better)
        XCTAssertEqual(IndexLevel(value: 3.9, direction: .higherIsBetter), .slightlyWorse)
        XCTAssertEqual(IndexLevel(value: 2.0, direction: .higherIsBetter), .slightlyWorse)
        XCTAssertEqual(IndexLevel(value: 1.9, direction: .higherIsBetter), .clearlyWorse)
        // Stress: high is bad
        XCTAssertEqual(IndexLevel(value: 8.0, direction: .lowerIsBetter), .slightlyWorse)
        XCTAssertEqual(IndexLevel(value: 8.1, direction: .lowerIsBetter), .clearlyWorse)
        XCTAssertEqual(IndexLevel(value: 3.0, direction: .lowerIsBetter), .better)
        XCTAssertEqual(IndexLevel.normalRange, 4.0...6.0)
    }

    func testChangeChipWordingAndColourDirection() throws {
        let up = try XCTUnwrap(ChangeChip(pct: 8.4, kind: .vsAverage, direction: .higherIsBetter))
        XCTAssertEqual(up.text, "▲ 8 % above average")
        XCTAssertEqual(up.shortText, "▲ 8 % vs avg")
        XCTAssertEqual(up.isGood, true)
        let down = try XCTUnwrap(ChangeChip(pct: -1.2, kind: .vsLast, direction: .higherIsBetter))
        XCTAssertEqual(down.text, "▼ 1 % since last measurement")
        XCTAssertEqual(down.isGood, false)
        // inverted metrics (Stress, resting HR): going down is good
        XCTAssertEqual(ChangeChip(pct: -5, kind: .vsAverage, direction: .lowerIsBetter)?.isGood, true)
        XCTAssertEqual(ChangeChip(pct: 5, kind: .vsLast, direction: .lowerIsBetter)?.isGood, false)
        // rounding to 0 is neutral, missing is no chip
        let flat = try XCTUnwrap(ChangeChip(pct: 0.4, kind: .vsAverage, direction: .higherIsBetter))
        XCTAssertNil(flat.isGood)
        XCTAssertEqual(flat.text, "= your average")
        XCTAssertNil(ChangeChip(pct: nil, kind: .vsLast, direction: .higherIsBetter))
        XCTAssertEqual(ChangeChip.chips(Comparison(vsAveragePct: nil, vsLastPct: 3), direction: .higherIsBetter).map(\.text),
                       ["▲ 3 % since last measurement"])
    }

    func testWeekStripRunsMondayToSunday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        cal.firstWeekday = 1   // a Sunday-first locale must still give Monday–Sunday
        func day(_ s: String) -> Date {
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.date(from: s)!
        }
        // Sunday 4 October 2026
        let strip = WeekStrip.days(containing: day("2026-10-04 07:30"),
                                   measuredDays: [day("2026-09-28 06:40"), day("2026-10-01 07:00"), day("2026-10-04 06:55"),
                                                  day("2026-09-27 07:00")],
                                   calendar: cal)
        XCTAssertEqual(strip.count, 7)
        XCTAssertEqual(strip.first?.date, day("2026-09-28 00:00"))
        XCTAssertEqual(strip.last?.date, day("2026-10-04 00:00"))
        XCTAssertEqual(strip.map(\.measured), [true, false, false, true, false, false, true])
        XCTAssertEqual(strip.filter(\.isToday).count, 1)
        XCTAssertTrue(strip.last!.isToday)
        XCTAssertFalse(strip.contains { $0.isFuture })
        // midweek: later days are in the future
        let wed = WeekStrip.days(containing: day("2026-09-30 12:00"), measuredDays: [], calendar: cal)
        XCTAssertEqual(wed.map(\.isFuture), [false, false, false, true, true, true, true])
    }
}
