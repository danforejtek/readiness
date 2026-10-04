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
    struct Case: Decodable { let rr: [Double]; let metrics: PyMetrics? }

    func testMatchesPython() throws {
        for c in try Fixtures.load("time_domain", as: [Case].self) {
            let m = computeMetrics(rr: c.rr, durationS: c.rr.dropFirst().reduce(0, +) / 1000, artefacts: 2)
            assertMetrics(m, c.metrics)
        }
    }
}

final class RRBufferTests: XCTestCase {
    struct Seq: Decodable { let inputs: [[Double]]; let values: [Double]; let times: [Double]; let beat_times: [Double]
                            let artefacts: Int; let total: Int; let window_2_5: [Double] }
    struct Packets: Decodable { let inputs: [[Double]]; let values: [Double]; let beat_times: [Double] }
    struct Fixture: Decodable { let sequential: Seq; let packets: Packets }

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
    struct Case: Decodable { let t: [Double]; let rr: [Double]; let spectral: PySpectral? }

    func testMatchesPythonLombScargle() throws {
        for c in try Fixtures.load("spectral", as: [Case].self) {
            assertSpectral(spectralMetrics(beatTimes: c.t, rrMs: c.rr), c.spectral)
        }
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
                             let spectral: PySpectral?; let artefacts: Int; let total: Int }

    func testRecordedBandSessionsMatchPython() throws {
        let cases = try Fixtures.load("sessions", as: [Case].self)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let b = RRBuffer()
            for beat in c.beats where beat[1] >= c.settle_s { b.add(beat[0], at: beat[1]) }
            XCTAssertEqual(b.artefacts, c.artefacts, c.file)
            XCTAssertEqual(b.total, c.total, c.file)
            assertMetrics(b.metrics(), c.metrics)
            assertSpectral(b.spectral(), c.spectral)
        }
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
