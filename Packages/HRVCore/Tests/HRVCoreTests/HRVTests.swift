import Foundation
import XCTest
@testable import HRVCore

final class ParserTests: XCTestCase {
    struct Case: Decodable { let hex: String; let hr: Int; let contact: Bool?; let energy: Int?; let rr_ms: [Double] }

    func testMatchesPythonParser() throws {
        for c in try Fixtures.load("parser", as: [Case].self) {
            let s = try HeartRateSample.parse(Data(hex: c.hex))
            XCTAssertEqual(s.heartRate, c.hr, c.hex)
            XCTAssertEqual(s.skinContact, c.contact, c.hex)
            XCTAssertEqual(s.energyExpendedKJ, c.energy, c.hex)
            XCTAssertEqual(s.rrIntervalsMs.count, c.rr_ms.count, c.hex)
            for (a, b) in zip(s.rrIntervalsMs, c.rr_ms) { XCTAssertClose(a, b) }
        }
    }

    func testTooShortThrows() {
        XCTAssertThrowsError(try HeartRateSample.parse(Data([0x10])))
    }
}

final class TimeDomainTests: XCTestCase {
    struct Case: Decodable { let rr: [Double]; let breaks: [Int]; let metrics: PyMetrics?; let poincare: [Double]?
                             let stress_index: Double? }

    func testMatchesPython() throws {
        let cases = try Fixtures.load("time_domain", as: [Case].self)
        for c in cases {
            let m = computeMetrics(rr: c.rr, durationS: c.rr.dropFirst().reduce(0, +) / 1000, artefacts: 2, breaks: c.breaks)
            assertMetrics(m, c.metrics)
            assertPoincare(poincare(rr: c.rr, breaks: c.breaks), c.poincare)
            assertOptional(stressIndex(rr: c.rr), c.stress_index, "stress index of \(c.rr.count) beats")
        }
        XCTAssertTrue(cases.contains { !$0.breaks.isEmpty }, "the fixture must exercise skipped differences")
    }

    func testDifferencesAcrossARejectedBeatAreSkipped() throws {
        // 1500 ms is rejected; the difference 1005 − 1010 spans it and must not enter RMSSD, pNN50 or SD1
        let b = RRBuffer()
        var t = 0.0
        for v in [1000.0, 1020, 990, 1010, 1500, 1005, 940, 1015, 995, 1060, 1000] { t += v / 1000; b.add(v, at: t) }
        let clean: [Double] = [1000, 1020, 990, 1010, 1005, 940, 1015, 995, 1060, 1000]
        XCTAssertEqual(b.values, clean)
        XCTAssertEqual(b.breaks, [4])
        let diffs: [Double] = [20, -30, 20, -65, 75, -20, 65, -60]
        let m = try XCTUnwrap(b.metrics())
        XCTAssertClose(m.rmssd, (diffs.map { $0 * $0 }.reduce(0, +) / 8).squareRoot())
        XCTAssertClose(m.pnn50, 50)
        XCTAssertClose(m.sdnn, Stats.stdev(clean))
        let pc = try XCTUnwrap(poincare(rr: b.values, breaks: b.breaks))
        XCTAssertClose(pc.sd1 * pc.sd1, Stats.variance(diffs) / 2)
    }

    func testStressIndexByHand() throws {
        // 18 × 1010 in [1000, 1050), 8 × 960, 4 × 1100: Mo = 1.025 s, AMo = 60 %, MxDMn = 0.140 s
        let rr = Array(repeating: 1010.0, count: 18) + Array(repeating: 960.0, count: 8) + Array(repeating: 1100.0, count: 4)
        XCTAssertClose(try XCTUnwrap(stressIndex(rr: rr)), 60 / (2 * 1.025 * 0.140))
        XCTAssertNil(stressIndex(rr: Array(rr.prefix(29))))
        XCTAssertNil(stressIndex(rr: Array(repeating: 1000, count: 40)))
    }
}

final class RRBufferTests: XCTestCase {
    struct Seq: Decodable { let inputs: [[Double]]; let values: [Double]; let times: [Double]; let beat_times: [Double]
                            let artefacts: Int; let total: Int; let window_2_5: [Double]; let breaks: [Int]
                            let metrics: PyMetrics; let metrics_4: PyMetrics }
    struct Packets: Decodable { let inputs: [[Double]]; let values: [Double]; let beat_times: [Double] }
    struct Step: Decodable { let inputs: [[Double]]; let values: [Double]; let artefacts: Int; let total: Int
                             let breaks: [Int]; let metrics: PyMetrics }
    struct Fixture: Decodable { let sequential: Seq; let packets: Packets; let step: Step }

    func testSequentialFilterAndWindow() throws {
        let fx = try Fixtures.load("rr_buffer", as: Fixture.self).sequential
        let b = RRBuffer()
        for p in fx.inputs { b.add(p[0], at: p[1]) }
        XCTAssertEqual(b.values, fx.values)
        XCTAssertEqual(b.artefacts, fx.artefacts)
        XCTAssertEqual(b.total, fx.total)
        XCTAssertEqual(b.times.count, fx.times.count)
        for (a, c) in zip(b.times, fx.times) { XCTAssertClose(a, c) }
        for (a, c) in zip(b.beatTimes, fx.beat_times) { XCTAssertClose(a, c) }
        XCTAssertEqual(b.window(2.5), fx.window_2_5)
        XCTAssertEqual(b.breaks, fx.breaks)
        assertMetrics(b.metrics(), fx.metrics)
        assertMetrics(b.metrics(window: 4.0), fx.metrics_4)
    }

    func testRecoversFromLevelShiftLikePython() throws {
        let fx = try Fixtures.load("rr_buffer", as: Fixture.self).step
        let b = RRBuffer()
        for p in fx.inputs { b.add(p[0], at: p[1]) }
        XCTAssertEqual(b.values, fx.values)
        XCTAssertEqual(b.artefacts, fx.artefacts)
        XCTAssertEqual(b.total, fx.total)
        XCTAssertEqual(b.breaks, fx.breaks)
        assertMetrics(b.metrics(), fx.metrics)
        // 10 × 1200 then 60 × 950 ms: only the first five beats of the new level are lost
        let shift = RRBuffer()
        var t = 0.0
        for v in Array(repeating: 1200.0, count: 10) + Array(repeating: 950.0, count: 60) { t += v / 1000; shift.add(v, at: t) }
        XCTAssertEqual(shift.artefacts, 5)
        XCTAssertEqual(shift.values.count, 65)
        XCTAssertEqual(shift.breaks, [10])       // the first accepted 950 follows the five rejected ones
    }

    func testBeatClockWithSharedPacketTimesAndResync() throws {
        let fx = try Fixtures.load("rr_buffer", as: Fixture.self).packets
        let b = RRBuffer()
        for p in fx.inputs { b.add(p[0], at: p[1]) }
        XCTAssertEqual(b.values, fx.values)
        for (a, c) in zip(b.beatTimes, fx.beat_times) { XCTAssertClose(a, c) }
    }
}

final class SpectralTests: XCTestCase {
    struct Case: Decodable { let t: [Double]; let rr: [Double]; let spectral: PySpectral?; let breathing_limit_hz: Double }

    func testMatchesPythonLombScargle() throws {
        for c in try Fixtures.load("spectral", as: [Case].self) {
            assertSpectral(spectralMetrics(beatTimes: c.t, rrMs: c.rr), c.spectral)
            XCTAssertEqual(breathingLimitHz(rrMs: c.rr), c.breathing_limit_hz)
        }
    }

    func testBreathingWindowStopsAtTheMeanNyquistFrequency() throws {
        XCTAssertClose(breathingLimitHz(rrMs: Array(repeating: 1200, count: 40)), 50.0 / 120.0)
        XCTAssertEqual(breathingLimitHz(rrMs: Array(repeating: 800, count: 40)), 0.5)
        let cases = try Fixtures.load("spectral", as: [Case].self)
        // 24 breaths/min at 50 bpm is found below the capped edge; 0.415 Hz peaks on the edge and is unresolved
        XCTAssertEqual(try XCTUnwrap(spectralMetrics(beatTimes: cases[5].t, rrMs: cases[5].rr)?.breathingRateBpm), 24, accuracy: 0.5)
        XCTAssertNil(try XCTUnwrap(spectralMetrics(beatTimes: cases[6].t, rrMs: cases[6].rr)).breathingRateBpm)
    }

    func testBreathingWindow() throws {
        let cases = try Fixtures.load("spectral", as: [Case].self)
        // 7 breaths/min lies below the HF band but inside the 6–30 /min window
        XCTAssertEqual(try XCTUnwrap(spectralMetrics(beatTimes: cases[3].t, rrMs: cases[3].rr)?.breathingRateBpm), 7, accuracy: 0.5)
        // 0.098 Hz peaks on the window's first bin: unresolved
        let edge = try XCTUnwrap(spectralMetrics(beatTimes: cases[4].t, rrMs: cases[4].rr))
        XCTAssertNil(edge.breathingRateBpm)
    }

    func testPhysics() throws {
        // 0.1 Hz sine of amplitude 50 ms carries variance 1250 ms², all of it in the LF band
        let c = try Fixtures.load("spectral", as: [Case].self)[0]
        let s = try XCTUnwrap(spectralMetrics(beatTimes: c.t, rrMs: c.rr))
        XCTAssertEqual(s.lfMs2, 1250, accuracy: 250)
        XCTAssertLessThan(s.hfMs2, 100)
    }
}

final class RealSessionTests: XCTestCase {
    struct Case: Decodable { let file: String; let settle_s: Double; let beats: [[Double]]; let metrics: PyMetrics?
                             let spectral: PySpectral?; let artefacts: Int; let total: Int; let breaks: [Int]
                             let poincare: [Double]?; let stress_index: Double? }

    func testRecordedBandSessionsMatchPython() throws {
        let cases = try Fixtures.load("sessions", as: [Case].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let b = RRBuffer()
            for beat in c.beats where beat[1] >= c.settle_s { b.add(beat[0], at: beat[1]) }
            XCTAssertEqual(b.artefacts, c.artefacts, c.file)
            XCTAssertEqual(b.total, c.total, c.file)
            XCTAssertEqual(b.breaks, c.breaks, c.file)
            assertMetrics(b.metrics(), c.metrics)
            assertSpectral(b.spectral(), c.spectral)
            assertPoincare(poincare(rr: b.values, breaks: b.breaks), c.poincare)
            assertOptional(stressIndex(rr: b.values), c.stress_index, c.file)
        }
        XCTAssertTrue(cases.contains { $0.stress_index != nil }, "a session long enough for the stress index")
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            bytes.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self.init(bytes)
    }
}

func assertPoincare(_ p: Poincare?, _ py: [Double]?, file: StaticString = #filePath, line: UInt = #line) {
    guard let py else { XCTAssertNil(p, file: file, line: line); return }
    guard let p else { XCTFail("expected Poincaré descriptors", file: file, line: line); return }
    XCTAssertClose(p.sd1, py[0], file: file, line: line)
    XCTAssertClose(p.sd2, py[1], file: file, line: line)
}

func assertOptional(_ mine: Double?, _ ref: Double?, rel: Double = 1e-9, _ ctx: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    switch (mine, ref) {
    case let (m?, r?): XCTAssertClose(m, r, rel: rel, ctx, file: file, line: line)
    case (nil, nil): break
    default: XCTFail("\(ctx): optional mismatch \(String(describing: mine)) vs \(String(describing: ref))", file: file, line: line)
    }
}
