import Foundation

/// Standard HRV frequency bands (Task Force 1996), Hz.
public enum HRVBands {
    public static let vlf = (0.003, 0.04)
    public static let lf = (0.04, 0.15)
    public static let hf = (0.15, 0.40)
    /// Breathing-rate search window (6–30 breaths/min): wider than HF so slow breathing is not misread. The upper
    /// edge is capped at the mean Nyquist frequency of the beat series, see `breathingLimitHz`.
    public static let breathing = (0.10, 0.50)
}

/// Upper edge of the breathing search: min(0.50 Hz, mean HR / 120), the mean Nyquist frequency of a series sampled
/// once per beat (Laguna 1998), e.g. 0.42 Hz at 50 bpm. Port of `hrmon.hrv.breathing_limit_hz`.
public func breathingLimitHz(rrMs: [Double]) -> Double {
    let meanRR = rrMs.reduce(0, +) / Double(rrMs.count)
    return min(HRVBands.breathing.1, (60000.0 / meanRR) / 120.0)
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
    /// Peak of 0.10 Hz up to min(0.50, HR / 120) Hz × 60, a rough respiration estimate; nil when the peak sits on
    /// the window's edge.
    public let breathingRateBpm: Double?
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

/// The band powers use the standard VLF/LF/HF bands. The breathing rate is the spectral peak between
/// `HRVBands.breathing.0` and `breathingLimitHz` on the same grid; a peak in the window's first or last bin is
/// unresolved (breathing outside the window, or no clear rhythm) and gives nil. Lomb-Scargle works on the real beat
/// times, so a rejected beat is simply a missing sample and needs no special handling.
public func spectralMetrics(beatTimes: [Double], rrMs: [Double], minBeats: Int = 30, minSpanS: Double = 60) -> SpectralMetrics? {
    guard rrMs.count >= minBeats, beatTimes[beatTimes.count - 1] - beatTimes[0] >= minSpanS else { return nil }
    let step = 0.002
    let count = Int((HRVBands.breathing.1 - HRVBands.vlf.0) / step) + 1
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
    let upper = breathingLimitHz(rrMs: rrMs)
    let window = freqs.indices.filter { HRVBands.breathing.0 <= freqs[$0] && freqs[$0] < upper }
    var breathing: Double?
    if let first = window.first, let last = window.last {
        var breathIdx = first
        for i in window where psd[i] > psd[breathIdx] { breathIdx = i }
        breathing = breathIdx == first || breathIdx == last ? nil : freqs[breathIdx] * 60.0
    }
    let lfhfSum = lf + hf
    return SpectralMetrics(
        vlfMs2: vlf, lfMs2: lf, hfMs2: hf, totalMs2: vlf + lf + hf,
        lfHf: hf > 0 ? lf / hf : .infinity,
        lfNu: lfhfSum > 0 ? 100.0 * lf / lfhfSum : 0,
        hfNu: lfhfSum > 0 ? 100.0 * hf / lfhfSum : 0,
        hfPeakHz: hfPeak, breathingRateBpm: breathing
    )
}
