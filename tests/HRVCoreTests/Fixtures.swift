import Foundation
import XCTest
@testable import HRVCore

/// Loads the JSON fixtures exported by `tools/export_fixtures.py` from the Python reference implementation.
enum Fixtures {
    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
                                "missing fixture \(name).json – run tools/export_fixtures.py")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

/// Python metrics dict (snake_case, NaN encoded as null).
struct PyMetrics: Decodable {
    let n: Int; let duration_s: Double; let mean_rr: Double; let mean_hr: Double; let sdnn: Double
    let rmssd: Double; let ln_rmssd: Double?; let pnn50: Double; let artefacts: Int; let artefact_pct: Double
}

struct PySpectral: Decodable {
    let vlf_ms2: Double; let lf_ms2: Double; let hf_ms2: Double; let total_ms2: Double; let lf_hf: Double?
    let lf_nu: Double; let hf_nu: Double; let hf_peak_hz: Double; let breathing_rate_bpm: Double
}

func XCTAssertClose(_ a: Double, _ b: Double, rel: Double = 1e-9, abs absTol: Double = 1e-9,
                    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let tol = max(absTol, rel * max(Swift.abs(a), Swift.abs(b)))
    XCTAssertEqual(a, b, accuracy: tol, message(), file: file, line: line)
}

func assertMetrics(_ m: HRVMetrics?, _ py: PyMetrics?, file: StaticString = #filePath, line: UInt = #line) {
    guard let py else { XCTAssertNil(m, file: file, line: line); return }
    guard let m else { XCTFail("expected metrics", file: file, line: line); return }
    XCTAssertEqual(m.n, py.n, file: file, line: line)
    XCTAssertClose(m.durationS, py.duration_s, file: file, line: line)
    XCTAssertClose(m.meanRR, py.mean_rr, file: file, line: line)
    XCTAssertClose(m.meanHR, py.mean_hr, file: file, line: line)
    XCTAssertClose(m.sdnn, py.sdnn, file: file, line: line)
    XCTAssertClose(m.rmssd, py.rmssd, file: file, line: line)
    if let ln = py.ln_rmssd { XCTAssertClose(m.lnRMSSD, ln, file: file, line: line) } else { XCTAssertTrue(m.lnRMSSD.isNaN, file: file, line: line) }
    XCTAssertClose(m.pnn50, py.pnn50, file: file, line: line)
    XCTAssertEqual(m.artefacts, py.artefacts, file: file, line: line)
    XCTAssertClose(m.artefactPct, py.artefact_pct, file: file, line: line)
}

func assertSpectral(_ s: SpectralMetrics?, _ py: PySpectral?, file: StaticString = #filePath, line: UInt = #line) {
    guard let py else { XCTAssertNil(s, file: file, line: line); return }
    guard let s else { XCTFail("expected spectral metrics", file: file, line: line); return }
    // identical algorithm and summation order: expect agreement far below 1e-6 relative
    XCTAssertClose(s.vlfMs2, py.vlf_ms2, rel: 1e-6, file: file, line: line)
    XCTAssertClose(s.lfMs2, py.lf_ms2, rel: 1e-6, file: file, line: line)
    XCTAssertClose(s.hfMs2, py.hf_ms2, rel: 1e-6, file: file, line: line)
    XCTAssertClose(s.totalMs2, py.total_ms2, rel: 1e-6, file: file, line: line)
    if let r = py.lf_hf { XCTAssertClose(s.lfHf, r, rel: 1e-6, file: file, line: line) } else { XCTAssertTrue(s.lfHf.isInfinite, file: file, line: line) }
    XCTAssertClose(s.lfNu, py.lf_nu, rel: 1e-6, file: file, line: line)
    XCTAssertClose(s.hfNu, py.hf_nu, rel: 1e-6, file: file, line: line)
    XCTAssertClose(s.hfPeakHz, py.hf_peak_hz, file: file, line: line)
    XCTAssertClose(s.breathingRateBpm, py.breathing_rate_bpm, file: file, line: line)
}
