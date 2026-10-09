import Foundation
import XCTest
@testable import HRVCore

final class InsightsTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-09-01T06:30:00Z")!

    /// `n` steady mornings with a small deterministic wobble; `tweak` adjusts single days.
    private func history(_ n: Int, minuteOffset: (Int) -> Int = { _ in 0 },
                         tweak: (Int) -> (ln: Double, hr: Double, feeling: Int?, tags: [String])? = { _ in nil }) -> [InsightDay] {
        var records: [DayRecord] = []
        var checkIns: [(Int?, [String])] = []
        for i in 0..<n {
            let when = start.addingTimeInterval(Double(i) * 86_400 + Double(minuteOffset(i)) * 60)
            let t = tweak(i)
            let ln = t?.ln ?? 4.0 + Double((i * 7) % 5 - 2) * 0.04
            let hr = t?.hr ?? 52.0 + Double((i * 3) % 5 - 2) * 0.8
            records.append(DayRecord(when: when, lnRMSSD: ln, rmssd: exp(ln), meanHR: hr, sdnn: 60, beats: 120, artefactPct: 2))
            checkIns.append((t?.feeling ?? 4, t?.tags ?? []))
        }
        return zip(Readiness.assessAll(records), checkIns).map { InsightDay(assessment: $0, feeling: $1.0, tags: $1.1) }
    }

    func testSpearmanAndQuantileMatchPython() throws {
        XCTAssertEqual(try XCTUnwrap(Insights.spearman([1, 2, 3, 4, 5], [2, 1, 4, 3, 5])), 0.8, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(Insights.spearman([1, 2, 2, 3], [1, 3, 2, 4])), 0.9486832980505138, accuracy: 1e-12)
        XCTAssertNil(Insights.spearman([1, 1, 1], [1, 2, 3]))
        XCTAssertEqual(Insights.quantile([1, 2, 3, 4], 0.25), 1.75, accuracy: 1e-12)
        XCTAssertEqual(Insights.quantile([5, 1, 3], 0.9), 4.6, accuracy: 1e-12)
    }

    func testRoutineHandlesMeasurementsAroundMidnight() throws {
        // Alternating 23:50 and 00:10 the next day: 20 minutes apart, not 23 hours.
        let days = history(10, minuteOffset: { i in i % 2 == 0 ? 17 * 60 + 20 : 17 * 60 + 40 })
        let r = try XCTUnwrap(Insights.report(days, calendar: utc).routine)
        XCTAssertLessThanOrEqual(r.spreadMinutes, 20)
        XCTAssertTrue(r.consistentTime)
        XCTAssertEqual(r.checkIns, 10)
    }

    func testFeelingMatchNeedsScoredCheckIns() throws {
        XCTAssertNil(Insights.report(history(10)).feeling)   // only 3 scored mornings
        // Bad mornings (low HRV, high HR) felt awful, the rest good: the verdict tracks the feeling.
        let days = history(30, tweak: { i in i >= 8 && i % 4 == 0 ? (3.7, 57, 2, []) : nil })
        let f = try XCTUnwrap(Insights.report(days).feeling)
        XCTAssertEqual(f.pairs, 23)   // mornings 8–30; the first 7 build the baseline
        XCTAssertFalse(f.preliminary)
        XCTAssertEqual(f.agreement, .tracks)
        let ready = try XCTUnwrap(f.byStatus.first { $0.status == .ready }?.meanFeeling)
        let rest = try XCTUnwrap(f.byStatus.first { $0.status == .rest }?.meanFeeling)
        XCTAssertGreaterThan(ready, rest)
    }

    func testTagEffectShowsLowerHRVAndHigherHR() throws {
        let days = history(30, tweak: { i in i >= 10 && i % 5 == 0 ? (3.8, 55, 3, ["alcohol"]) : nil })
        let report = Insights.report(days)
        let alcohol = try XCTUnwrap(report.tags.first { $0.tag == "alcohol" })
        XCTAssertEqual(alcohol.mornings, 4)
        XCTAssertLessThan(alcohol.hrvPct, -10)
        XCTAssertGreaterThan(alcohol.hrBpm, 2)
        XCTAssertLessThan(alcohol.zHRV, 0)
        XCTAssertNil(report.tags.first { $0.tag == "poor_sleep" })   // never tagged
    }

    func testIllnessCheckSortsCaughtMissedAndUnexplained() throws {
        // Days 15–16: HR far up, tagged sick on 15 → the warning on 16 catches it. Day 22: tagged sick, nothing
        // measured → missed. Days 27–28: HR far up, no tag → one unexplained warning (on 28).
        let days = history(30, tweak: { i in
            switch i {
            case 15: return (3.8, 60, 1, ["sick"])
            case 16: return (3.8, 60, 2, [])
            case 22: return (4.0, 52, 2, ["sick"])
            case 27, 28: return (3.8, 60, 3, [])
            default: return nil
            }
        })
        // the warning needs two flagged mornings in a row: the first of each pair is only a signal
        XCTAssertEqual(days.filter(\.assessment.illness).count, 2)
        XCTAssertEqual(days.filter(\.assessment.illnessSignal).count, 4)
        let ill = try XCTUnwrap(Insights.report(days).illness)
        XCTAssertEqual(ill.caught.count, 1)
        XCTAssertEqual(ill.missed.count, 1)
        XCTAssertEqual(ill.unexplained.count, 1)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
}
