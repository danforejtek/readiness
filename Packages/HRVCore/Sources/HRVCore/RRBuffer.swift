import Foundation

/// Keeps clean RR intervals with timestamps; rejects implausible beats. Port of `hrmon.hrv.RRBuffer`.
///
/// An interval is an artefact when it is outside [minRR, maxRR] ms or deviates more than `maxDeviation` from the
/// median of the last few accepted ones. Recovery from a genuine level shift: after `history` deviation rejections
/// in a row (range rejections do not count) that agree with each other (each within `maxDeviation` of their own
/// median), they become the new reference; they stay counted as artefacts.
/// `times` are packet arrival times (windowing); `beatTimes` are reconstructed from the cumulative RR sum
/// (spectral analysis), re-synced to packet time when they drift apart by more than 1.5 s.
/// `breaks` lists the indices i ≥ 1 of `values` whose interval directly follows at least one rejected one, so
/// values[i] − values[i−1] spans a removed beat; the metrics skip those differences.
public final class RRBuffer {
    public let minRR: Double
    public let maxRR: Double
    public let maxDeviation: Double
    public private(set) var times: [Double] = []
    public private(set) var beatTimes: [Double] = []
    public private(set) var values: [Double] = []
    public private(set) var breaks: [Int] = []
    public private(set) var artefacts = 0
    public private(set) var total = 0
    private var recent: [Double] = []
    /// Deviation rejections since the last accepted beat (at most `history`).
    private var rejected: [Double] = []
    private let history: Int
    private var beatClock: Double?
    private var afterRejection = false

    public init(minRR: Double = 300, maxRR: Double = 2000, maxDeviation: Double = 0.20, history: Int = 5) {
        self.minRR = minRR; self.maxRR = maxRR; self.maxDeviation = maxDeviation; self.history = history
    }

    /// Add one interval observed at elapsed time `t`. Returns true if accepted.
    @discardableResult
    public func add(_ rrMs: Double, at t: Double) -> Bool {
        total += 1
        if let clock = beatClock, abs(clock + rrMs / 1000.0 - t) <= 1.5 {
            beatClock = clock + rrMs / 1000.0
        } else {
            beatClock = t
        }
        guard minRR <= rrMs && rrMs <= maxRR else { artefacts += 1; afterRejection = true; return false }
        if recent.count >= 3, !close(rrMs, Stats.median(recent)) {
            artefacts += 1
            afterRejection = true
            rejected.append(rrMs)
            if rejected.count > history { rejected.removeFirst() }
            if rejected.count == history {
                let med = Stats.median(rejected)
                if rejected.allSatisfy({ close($0, med) }) {
                    recent = rejected
                    rejected.removeAll()
                }
            }
            return false
        }
        rejected.removeAll()
        recent.append(rrMs)
        if recent.count > history { recent.removeFirst() }
        if afterRejection && !values.isEmpty { breaks.append(values.count) }
        afterRejection = false
        times.append(t)
        beatTimes.append(beatClock!)
        values.append(rrMs)
        return true
    }

    private func close(_ rrMs: Double, _ ref: Double) -> Bool { abs(rrMs - ref) / ref <= maxDeviation }

    private func startIndex(window seconds: Double?) -> Int {
        guard let seconds, let last = times.last else { return 0 }
        let cutoff = last - seconds
        // first index with times[i] >= cutoff (bisect_left)
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < cutoff { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public func window(_ seconds: Double? = nil) -> [Double] {
        Array(values[startIndex(window: seconds)...])
    }

    /// `breaks` relative to the start of `window(seconds)` (a break on the window's first beat is dropped).
    public func windowBreaks(_ seconds: Double? = nil) -> [Int] {
        let start = startIndex(window: seconds)
        return breaks.filter { $0 > start }.map { $0 - start }
    }

    public func metrics(window seconds: Double? = nil) -> HRVMetrics? {
        let vals = window(seconds)
        guard vals.count >= 2 else { return nil }
        let duration = times[times.count - 1] - times[times.count - vals.count]
        return computeMetrics(rr: vals, durationS: duration, artefacts: seconds == nil ? artefacts : 0,
                              breaks: windowBreaks(seconds))
    }

    public func spectral(window seconds: Double? = nil) -> SpectralMetrics? {
        let i = startIndex(window: seconds)
        return spectralMetrics(beatTimes: Array(beatTimes[i...]), rrMs: Array(values[i...]))
    }
}
