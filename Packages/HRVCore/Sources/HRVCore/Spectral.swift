import Foundation

/// Standard HRV frequency bands (Task Force 1996), Hz.
public enum HRVBands {
    public static let vlf = (0.003, 0.04)
    public static let lf = (0.04, 0.15)
    public static let hf = (0.15, 0.40)
}

/// Frequency-domain HRV. Port of `hrmon.hrv.spectral_metrics`.
public struct SpectralMetrics: Equatable, Sendable, Codable {
    public let vlfMs2: Double
    public let lfMs2: Double
    public let hfMs2: Double
    public let totalMs2: Double
    public let lfHf: Double
    public let lfNu: Double
    public let hfNu: Double
    public let hfPeakHz: Double
    public let breathingRateBpm: Double
}

/// Lomb-Scargle PSD of unevenly sampled data, scaled so the integral over frequency equals the variance
/// (classic periodogram × 2 × mean sampling interval). Units: y² per Hz.
public func lombScarglePSD(t: [Double], y: [Double], freqs: [Double]) -> [Double] {
    let n = t.count
    let mean = y.reduce(0, +) / Double(n)
    let yc = y.map { $0 - mean }
    let meanDt = (t[n - 1] - t[0]) / Double(n - 1)
    var out: [Double] = []
    out.reserveCapacity(freqs.count)
    for f in freqs {
        let w = 2.0 * Double.pi * f
        var s2 = 0.0, c2 = 0.0
        for ti in t { s2 += sin(2.0 * w * ti); c2 += cos(2.0 * w * ti) }
        let tau = atan2(s2, c2) / (2.0 * w)
        var cs = 0.0, ss = 0.0, cc = 0.0, sq = 0.0
        for (ti, yi) in zip(t, yc) {
            let a = w * (ti - tau)
            let c = cos(a), s = sin(a)
            cs += yi * c; ss += yi * s; cc += c * c; sq += s * s
        }
        let p = 0.5 * ((cc > 0 ? cs * cs / cc : 0) + (sq > 0 ? ss * ss / sq : 0))
        out.append(2.0 * meanDt * p)
    }
    return out
}

public func spectralMetrics(beatTimes: [Double], rrMs: [Double], minBeats: Int = 30, minSpanS: Double = 60) -> SpectralMetrics? {
    guard rrMs.count >= minBeats, beatTimes[beatTimes.count - 1] - beatTimes[0] >= minSpanS else { return nil }
    let step = 0.002
    let count = Int((HRVBands.hf.1 - HRVBands.vlf.0) / step) + 1
    let freqs = (0..<count).map { HRVBands.vlf.0 + Double($0) * step }
    let psd = lombScarglePSD(t: beatTimes, y: rrMs, freqs: freqs)

    func band(_ lo: Double, _ hi: Double) -> Double {
        var sum = 0.0
        for (f, p) in zip(freqs, psd) where lo <= f && f < hi { sum += p * step }
        return sum
    }
    let vlf = band(HRVBands.vlf.0, HRVBands.vlf.1)
    let lf = band(HRVBands.lf.0, HRVBands.lf.1)
    let hf = band(HRVBands.hf.0, HRVBands.hf.1)
    var peakIdx = -1
    for i in freqs.indices where HRVBands.hf.0 <= freqs[i] && freqs[i] < HRVBands.hf.1 {
        if peakIdx < 0 || psd[i] > psd[peakIdx] { peakIdx = i }
    }
    let hfPeak = freqs[peakIdx]
    let lfhfSum = lf + hf
    return SpectralMetrics(
        vlfMs2: vlf, lfMs2: lf, hfMs2: hf, totalMs2: vlf + lf + hf,
        lfHf: hf > 0 ? lf / hf : .infinity,
        lfNu: lfhfSum > 0 ? 100.0 * lf / lfhfSum : 0,
        hfNu: lfhfSum > 0 ? 100.0 * hf / lfhfSum : 0,
        hfPeakHz: hfPeak, breathingRateBpm: hfPeak * 60.0
    )
}
