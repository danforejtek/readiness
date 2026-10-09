import Foundation

/// Time-domain HRV metrics. Port of `hrmon.hrv.compute_metrics`.
public struct HRVMetrics: Equatable, Sendable, Codable {
    public let n: Int
    public let durationS: Double
    public let meanRR: Double
    public let meanHR: Double
    public let sdnn: Double
    public let rmssd: Double
    public let lnRMSSD: Double
    public let pnn50: Double
    public let artefacts: Int
    public let artefactPct: Double

    public init(n: Int, durationS: Double, meanRR: Double, meanHR: Double, sdnn: Double, rmssd: Double,
                lnRMSSD: Double, pnn50: Double, artefacts: Int, artefactPct: Double) {
        self.n = n; self.durationS = durationS; self.meanRR = meanRR; self.meanHR = meanHR
        self.sdnn = sdnn; self.rmssd = rmssd; self.lnRMSSD = lnRMSSD; self.pnn50 = pnn50
        self.artefacts = artefacts; self.artefactPct = artefactPct
    }
}

enum Stats {
    static func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }

    /// Sample standard deviation (n − 1), like Python's `statistics.stdev`.
    static func stdev(_ xs: [Double]) -> Double {
        let m = mean(xs)
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }

    /// Sample variance (n − 1), like Python's `statistics.variance`.
    static func variance(_ xs: [Double]) -> Double {
        let m = mean(xs)
        return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

/// rr[i] − rr[i−1] for every i ≥ 1 that is not in `breaks`. Port of `hrmon.hrv.successive_differences`.
///
/// `breaks` holds the indices whose interval directly follows a rejected one (`RRBuffer.breaks`): the difference
/// across a removed beat is not a real beat-to-beat change and would inflate RMSSD, pNN50 and SD1
/// (Lipponen & Tarvainen 2019).
public func successiveDifferences(rr: [Double], breaks: [Int] = []) -> [Double] {
    guard rr.count >= 2 else { return [] }
    let skip = Set(breaks)
    return (1..<rr.count).filter { !skip.contains($0) }.map { rr[$0] - rr[$0 - 1] }
}

/// Time-domain HRV of clean RR intervals (ms). RMSSD and pNN50 use only the successive differences that do not
/// span a rejected beat (`breaks`); SDNN and mean RR/HR use every interval.
public func computeMetrics(rr: [Double], durationS: Double = 0, artefacts: Int = 0, breaks: [Int] = []) -> HRVMetrics? {
    guard rr.count >= 2 else { return nil }
    let meanRR = Stats.mean(rr)
    let sdnn = Stats.stdev(rr)
    let diffs = successiveDifferences(rr: rr, breaks: breaks)
    let rmssd = diffs.isEmpty ? 0 : Stats.mean(diffs.map { $0 * $0 }).squareRoot()
    let pnn50 = diffs.isEmpty ? 0 : 100.0 * Double(diffs.filter { abs($0) > 50.0 }.count) / Double(diffs.count)
    let total = rr.count + artefacts
    return HRVMetrics(
        n: rr.count, durationS: durationS, meanRR: meanRR, meanHR: 60000.0 / meanRR,
        sdnn: sdnn, rmssd: rmssd, lnRMSSD: rmssd > 0 ? log(rmssd) : .nan, pnn50: pnn50,
        artefacts: artefacts, artefactPct: total > 0 ? 100.0 * Double(artefacts) / Double(total) : 0
    )
}

/// Poincaré descriptors in ms. Port of `hrmon.hrv.poincare`.
/// SD1 is the short-term, beat-to-beat spread across the identity line (≈ RMSSD/√2);
/// SD2 is the longer-term spread along it. Differences across a rejected beat (`breaks`) are left out.
public struct Poincare: Equatable, Sendable {
    public let sd1: Double
    public let sd2: Double
    public init(sd1: Double, sd2: Double) { self.sd1 = sd1; self.sd2 = sd2 }
}

public func poincare(rr: [Double], breaks: [Int] = []) -> Poincare? {
    guard rr.count >= 3 else { return nil }
    let diffs = successiveDifferences(rr: rr, breaks: breaks)
    guard diffs.count >= 2 else { return nil }
    let sd1Sq = 0.5 * Stats.variance(diffs)
    let sd2Sq = max(0, 2 * Stats.variance(rr) - sd1Sq)
    return Poincare(sd1: sd1Sq.squareRoot(), sd2: sd2Sq.squareRoot())
}

/// Baevsky's stress index on clean RR (ms): SI = AMo / (2 · Mo · MxDMn). Port of `hrmon.hrv.stress_index`.
/// The intervals go into `binMs` wide bins on a fixed grid ([0, 50), [50, 100), … ms). Mo is the centre of the
/// fullest bin in s (the lowest one on a tie), AMo the % of intervals in it, MxDMn the spread max − min in s.
/// A narrow, peaked histogram (rigid rhythm) gives a high SI.
public func stressIndex(rr: [Double], binMs: Double = 50, minBeats: Int = 30) -> Double? {
    guard rr.count >= minBeats, let lo = rr.min(), let hi = rr.max() else { return nil }
    let mxdmn = (hi - lo) / 1000
    guard mxdmn > 0 else { return nil }
    var counts: [Int: Int] = [:]
    for v in rr { counts[Int((v / binMs).rounded(.down)), default: 0] += 1 }
    guard let mode = counts.min(by: { ($1.value, $0.key) < ($0.value, $1.key) }) else { return nil }
    let mo = (Double(mode.key) + 0.5) * binMs / 1000
    let amo = 100 * Double(mode.value) / Double(rr.count)
    return amo / (2 * mo * mxdmn)
}
