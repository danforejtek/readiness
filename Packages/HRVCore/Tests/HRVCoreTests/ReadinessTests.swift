import Foundation
import XCTest
@testable import HRVCore

struct PyRecord: Decodable {
    let when: String; let ln_rmssd: Double; let rmssd: Double; let mean_hr: Double; let sdnn: Double
    let beats: Int; let artefact_pct: Double; let hf_ms2: Double?; let lf_ms2: Double?; let breathing_rate: Double?
    let mean_rr: Double?; let sd1: Double?; let sd2: Double?; let stress_index: Double?

    func record(_ fmt: DateFormatter) throws -> DayRecord {
        DayRecord(when: try XCTUnwrap(fmt.date(from: when)), lnRMSSD: ln_rmssd, rmssd: rmssd, meanHR: mean_hr, sdnn: sdnn,
                  beats: beats, artefactPct: artefact_pct, hfMs2: hf_ms2, lfMs2: lf_ms2, breathingRate: breathing_rate,
                  meanRR: mean_rr, sd1: sd1, sd2: sd2, stressIndex: stress_index)
    }
}

struct PyAssessment: Decodable {
    let status: String; let score: Int?; let baseline_n: Int; let ln_mean: Double?; let ln_sd: Double?; let ln_week: Double?
    let week_n: Int
    let hr_mean: Double?; let hr_sd: Double?; let z_hrv: Double?; let z_hr: Double?; let illness: Bool
    let illness_streak: Int; let low_confidence: Bool; let notes: [String]
    let regeneration: Double?; let stress: Double?; let z_regeneration: Double?; let z_stress: Double?
    /// [vs average %, vs last %]
    let ln_change: [Double?]; let hr_change: [Double?]; let regeneration_change: [Double?]; let stress_change: [Double?]
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
            XCTAssertEqual(a.weekN, py.week_n, ctx)
            XCTAssertEqual(a.illness, py.illness, ctx)
            XCTAssertEqual(a.illnessStreak, py.illness_streak, ctx)
            XCTAssertEqual(a.lowConfidence, py.low_confidence, ctx)
            XCTAssertEqual(a.notes, py.notes, ctx)
            for (mine, ref) in [(a.lnMean, py.ln_mean), (a.lnSD, py.ln_sd), (a.lnWeek, py.ln_week), (a.hrMean, py.hr_mean),
                                (a.hrSD, py.hr_sd), (a.zHRV, py.z_hrv), (a.zHR, py.z_hr),
                                (a.zRegeneration, py.z_regeneration), (a.zStress, py.z_stress)] {
                assertOptional(mine, ref, ctx)
            }
            // the 0–10 values are rounded to one decimal on both sides, so they must match exactly
            XCTAssertEqual(a.regeneration, py.regeneration, ctx)
            XCTAssertEqual(a.stress, py.stress, ctx)
            for (name, mine, ref) in [("ln", a.lnChange, py.ln_change), ("hr", a.hrChange, py.hr_change),
                                      ("regeneration", a.regenerationChange, py.regeneration_change),
                                      ("stress", a.stressChange, py.stress_change)] {
                assertOptional(mine.vsAveragePct, ref[0], "\(ctx) \(name) vs average")
                assertOptional(mine.vsLastPct, ref[1], "\(ctx) \(name) vs last")
            }
            statuses.insert(py.status)
        }
        // the fixture must exercise every verdict, otherwise the comparison proves little
        XCTAssertEqual(statuses, ["baseline", "ready", "moderate", "rest"])
        XCTAssertTrue(fx.assessments.contains { $0.illness_streak == 2 })
        XCTAssertTrue(fx.assessments.contains { $0.illness_streak == 3 })
        // resting HR z ≥ 2.5 but less than 4 bpm up is not an illness warning
        XCTAssertTrue(fx.assessments.contains { ($0.z_hr ?? 0) >= 2.5 && !$0.illness })
        // after a noisy morning the baseline leaves it out
        XCTAssertTrue(zip(fx.assessments, fx.assessments.dropFirst()).contains { $0.low_confidence && $1.baseline_n == $0.baseline_n })
        // … and the 0–10 indices: clipped at both ends, and Stress present on a day without SD2 (resting HR alone)
        XCTAssertTrue(fx.assessments.contains { $0.regeneration == 0 } && fx.assessments.contains { $0.stress == 10 })
        XCTAssertTrue(zip(fx.records, fx.assessments).contains { $0.sd2 == nil && $1.stress != nil })
        // Regeneration is the HRV z-score itself
        for a in fx.assessments where a.z_hrv != nil { assertOptional(a.z_regeneration, a.z_hrv) }
        // a 7-day average below range with only two mornings in its window does not flag fatigue
        XCTAssertTrue(fx.assessments.contains { a in
            guard let week = a.ln_week, let m = a.ln_mean, let sd = a.ln_sd else { return false }
            return week < m - 0.5 * sd && a.week_n < Readiness.weekMinDays && a.status == "ready"
        })
    }

    func testRegenerationAndStressComposition() throws {
        let start = try XCTUnwrap(Self.fmt.date(from: "2026-09-01 07:00"))
        func day(_ i: Int, ln: Double, hr: Double, sd2: Double?) -> DayRecord {
            DayRecord(when: Readiness.calendar.date(byAdding: .day, value: i, to: start)!, lnRMSSD: ln, rmssd: exp(ln),
                      meanHR: hr, sdnn: 60, beats: 120, artefactPct: 2, meanRR: 60000 / hr, sd1: 40, sd2: sd2, stressIndex: 100)
        }
        var records: [DayRecord] = []
        for i in 0..<30 {
            let w = Double((i * 7) % 5 - 2), v = Double((i * 3) % 5 - 2)
            records.append(day(i, ln: 4.0 + w * 0.04, hr: 52 + v * 0.8, sd2: 80 - w * 3))
        }
        records.append(day(30, ln: 3.7, hr: 58, sd2: 60))
        let a = Readiness.assess(records)
        let hist = Array(records.dropLast())
        let hrs: [Double] = hist.map { $0.meanHR }
        let zHR = (58 - Stats.mean(hrs)) / max(Stats.stdev(hrs), Readiness.hrSDFloor)
        let lnSD2 = hist.map { log($0.sd2!) }
        let zSD2 = (log(60.0) - Stats.mean(lnSD2)) / max(Stats.stdev(lnSD2), Readiness.lnSD2SDFloor)
        XCTAssertClose(try XCTUnwrap(a.zStress), 2.0 / 3.0 * zHR - 1.0 / 3.0 * zSD2)
        XCTAssertClose(try XCTUnwrap(a.zRegeneration), try XCTUnwrap(a.zHRV))
        // without SD2 today, Stress is resting HR alone
        records[30] = day(30, ln: 3.7, hr: 58, sd2: nil)
        XCTAssertClose(try XCTUnwrap(Readiness.assess(records).zStress), zHR)
    }

    func testIllnessNotesNameOtherCauses() throws {
        let fx = try Fixtures.load("readiness", as: Fixture.self)
        let records = try fx.records.map { try $0.record(Self.fmt) }
        let notes = Readiness.assessAll(records).flatMap(\.notes)
        XCTAssertTrue(notes.contains { $0.contains("one to three days before a cold or other infection, but alcohol, poor sleep, travel and stress produce it too") })
        XCTAssertTrue(notes.contains { $0.contains("far outside your usual range. Infection, alcohol, poor sleep, travel, heavy stress or a late meal can all do this.") })
    }

    func testIllnessStreakIsLinearAndUncapped() throws {
        let start = try XCTUnwrap(Self.fmt.date(from: "2026-09-01 07:00"))
        var records: [DayRecord] = []
        for i in 0..<60 {
            let ill = i >= 46
            let ln = ill ? 3.8 : 4.0 + Double((i * 7) % 5 - 2) * 0.04
            let hr = ill ? 60.0 : 52.0 + Double((i * 3) % 5 - 2) * 0.8
            records.append(DayRecord(when: Readiness.calendar.date(byAdding: .day, value: i, to: start)!, lnRMSSD: ln,
                                     rmssd: 55, meanHR: hr, sdnn: 60, beats: 120, artefactPct: 2))
        }
        let begin = Date()
        let all = Readiness.assessAll(records)
        XCTAssertLessThan(Date().timeIntervalSince(begin), 1.0)
        XCTAssertEqual(all.last?.illnessStreak, 14)
        // a day without a measurement ends the streak
        var gap = records
        gap.remove(at: 55)
        XCTAssertEqual(Readiness.assess(gap).illnessStreak, 4)
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
            XCTAssertEqual(g.meanRR, w.meanRR)
            XCTAssertEqual(g.sd1, w.sd1)
            XCTAssertEqual(g.sd2, w.sd2)
            XCTAssertEqual(g.stressIndex, w.stressIndex)
        }
        XCTAssertTrue(got.contains { $0.stressIndex != nil })
    }

    func testRowRoundTripThroughText() throws {
        let m = try XCTUnwrap(computeMetrics(rr: [1000, 1050, 950, 1000, 1100, 900], durationS: 5, artefacts: 1))
        let when = try XCTUnwrap(ReadinessTests.fmt.date(from: "2026-10-04 07:00"))
        let row = ReadinessCSV.row(when: when, metrics: m, spectral: nil, settleS: 15,
                                   poincare: poincare(rr: [1000, 1050, 950, 1000, 1100, 900]), stressIndex: 123.45)
        let text = ReadinessCSV.text(rows: [row])
        let parsed = CSV.parse(text)
        XCTAssertEqual(parsed.headers, ReadinessCSV.columns)
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.rows[0]["date"], "2026-10-04 07:00")
        XCTAssertEqual(parsed.rows[0]["quality"], "fair")  // 1 artefact in 7 beats = 14 %
        XCTAssertEqual(parsed.rows[0]["lf_hf"], "")
        let recs = ReadinessCSV.records(fromText: text)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].beats, 6)
        XCTAssertEqual(recs[0].stressIndex, 123.5)
        XCTAssertNotNil(recs[0].sd1)
        XCTAssertEqual(Array(ReadinessCSV.columns.suffix(3)), ["sd1_ms", "sd2_ms", "stress_index"])
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
