import Foundation
import XCTest
@testable import HRVCore

struct PyRecord: Decodable {
    let when: String; let ln_rmssd: Double; let rmssd: Double; let mean_hr: Double; let sdnn: Double
    let beats: Int; let artefact_pct: Double; let hf_ms2: Double?; let lf_ms2: Double?; let breathing_rate: Double?

    func record(_ fmt: DateFormatter) throws -> DayRecord {
        DayRecord(when: try XCTUnwrap(fmt.date(from: when)), lnRMSSD: ln_rmssd, rmssd: rmssd, meanHR: mean_hr, sdnn: sdnn,
                  beats: beats, artefactPct: artefact_pct, hfMs2: hf_ms2, lfMs2: lf_ms2, breathingRate: breathing_rate)
    }
}

struct PyAssessment: Decodable {
    let status: String; let score: Int?; let baseline_n: Int; let ln_mean: Double?; let ln_sd: Double?; let ln_week: Double?
    let hr_mean: Double?; let hr_sd: Double?; let z_hrv: Double?; let z_hr: Double?; let illness: Bool
    let illness_streak: Int; let low_confidence: Bool; let notes: [String]
}

final class ReadinessTests: XCTestCase {
    struct Fixture: Decodable { let records: [PyRecord]; let assessments: [PyAssessment] }

    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Readiness.calendar
        f.timeZone = Readiness.calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    func testEveryDayMatchesPython() throws {
        let fx = try Fixtures.load("readiness", as: Fixture.self)
        let records = try fx.records.map { try $0.record(Self.fmt) }
        let got = Readiness.assessAll(records)
        XCTAssertEqual(got.count, fx.assessments.count)
        var statuses = Set<String>()
        for (i, (a, py)) in zip(got, fx.assessments).enumerated() {
            let ctx = "day \(i) \(fx.records[i].when)"
            XCTAssertEqual(a.status.rawValue, py.status, ctx)
            XCTAssertEqual(a.score, py.score, ctx)
            XCTAssertEqual(a.baselineN, py.baseline_n, ctx)
            XCTAssertEqual(a.illness, py.illness, ctx)
            XCTAssertEqual(a.illnessStreak, py.illness_streak, ctx)
            XCTAssertEqual(a.lowConfidence, py.low_confidence, ctx)
            XCTAssertEqual(a.notes, py.notes, ctx)
            for (mine, ref) in [(a.lnMean, py.ln_mean), (a.lnSD, py.ln_sd), (a.lnWeek, py.ln_week), (a.hrMean, py.hr_mean),
                                (a.hrSD, py.hr_sd), (a.zHRV, py.z_hrv), (a.zHR, py.z_hr)] {
                switch (mine, ref) {
                case let (m?, r?): XCTAssertClose(m, r, ctx)
                case (nil, nil): break
                default: XCTFail("\(ctx): optional mismatch \(String(describing: mine)) vs \(String(describing: ref))")
                }
            }
            statuses.insert(py.status)
        }
        // the fixture must exercise every verdict, otherwise the comparison proves little
        XCTAssertEqual(statuses, ["baseline", "ready", "moderate", "rest"])
        XCTAssertTrue(fx.assessments.contains { $0.illness_streak == 2 })
    }

    func testRangesDerivedFromBaseline() throws {
        let fx = try Fixtures.load("readiness", as: Fixture.self)
        let records = try fx.records.map { try $0.record(Self.fmt) }
        let a = Readiness.assess(records, index: 30)
        let ln = try XCTUnwrap(a.lnRange), hr = try XCTUnwrap(a.hrRange)
        XCTAssertClose(ln.upperBound - ln.lowerBound, a.lnSD!)
        XCTAssertClose(hr.upperBound - hr.lowerBound, a.hrSD!)
    }
}

final class CSVTests: XCTestCase {
    struct Fixture: Decodable { let rows: [[String: String]]; let records: [PyRecord] }

    func testReadinessRowsGroupPerDayLikePython() throws {
        let fx = try Fixtures.load("readiness_rows", as: Fixture.self)
        let got = ReadinessCSV.records(from: fx.rows)
        let want = try fx.records.map { try $0.record(ReadinessTests.fmt) }
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.when, w.when)
            XCTAssertClose(g.lnRMSSD, w.lnRMSSD)
            XCTAssertClose(g.meanHR, w.meanHR)
            XCTAssertEqual(g.beats, w.beats)
            XCTAssertEqual(g.hfMs2, w.hfMs2)
            XCTAssertEqual(g.breathingRate, w.breathingRate)
        }
    }

    func testRowRoundTripThroughText() throws {
        let m = try XCTUnwrap(computeMetrics(rr: [1000, 1050, 950, 1000, 1100, 900], durationS: 5, artefacts: 1))
        let when = try XCTUnwrap(ReadinessTests.fmt.date(from: "2026-10-04 07:00"))
        let row = ReadinessCSV.row(when: when, metrics: m, spectral: nil, settleS: 15)
        let text = ReadinessCSV.text(rows: [row])
        let parsed = CSV.parse(text)
        XCTAssertEqual(parsed.headers, ReadinessCSV.columns)
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.rows[0]["date"], "2026-10-04 07:00")
        XCTAssertEqual(parsed.rows[0]["quality"], "poor")
        XCTAssertEqual(parsed.rows[0]["lf_hf"], "")
        let recs = ReadinessCSV.records(fromText: text)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].beats, 6)
    }

    func testSessionCSVBeats() {
        let text = "timestamp_iso,elapsed_s,hr_bpm,rr_ms,contact,battery_pct\n2026-10-03T23:53:30.063,0.000,63,781.2,,100\n2026-10-03T23:54:28.097,58.036,94,,,100\n"
        let beats = SessionCSV.beats(fromText: text)
        XCTAssertEqual(beats.count, 2)
        XCTAssertEqual(beats[0].rrMs, 781.2)
        XCTAssertNil(beats[1].rrMs)
        XCTAssertEqual(beats[1].hr, 94)
    }

    func testQuotedFields() {
        let p = CSV.parse("a,b\n\"x, y\",2\n")
        XCTAssertEqual(p.rows[0]["a"], "x, y")
        XCTAssertEqual(CSV.line(["x, y", "2"]), "\"x, y\",2")
    }
}
