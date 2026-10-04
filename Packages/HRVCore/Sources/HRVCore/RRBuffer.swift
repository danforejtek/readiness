import Foundation

/// Keeps clean RR intervals with timestamps; rejects implausible beats. Port of `hrmon.hrv.RRBuffer`.
///
/// `times` are packet arrival times (windowing); `beatTimes` are reconstructed from the cumulative RR sum
/// (spectral analysis), re-synced to packet time when they drift apart by more than 1.5 s.
public final class RRBuffer {
    public let minRR: Double
    public let maxRR: Double
    public let maxDeviation: Double
    public private(set) var times: [Double] = []
    public private(set) var beatTimes: [Double] = []
    public private(set) var values: [Double] = []
    public private(set) var artefacts = 0
    public private(set) var total = 0
    private var recent: [Double] = []
    private let history: Int
    private var beatClock: Double?

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
        var ok = minRR <= rrMs && rrMs <= maxRR
        if ok, recent.count >= 3 {
            let med = Stats.median(recent)
            ok = abs(rrMs - med) / med <= maxDeviation
        }
        guard ok else { artefacts += 1; return false }
        recent.append(rrMs)
        if recent.count > history { recent.removeFirst() }
        times.append(t)
        beatTimes.append(beatClock!)
        values.append(rrMs)
        return true
    }

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

    public func metrics(window seconds: Double? = nil) -> HRVMetrics? {
        let vals = window(seconds)
        guard vals.count >= 2 else { return nil }
        let duration = times[times.count - 1] - times[times.count - vals.count]
        return computeMetrics(rr: vals, durationS: duration, artefacts: seconds == nil ? artefacts : 0)
    }

    public func spectral(window seconds: Double? = nil) -> SpectralMetrics? {
        let i = startIndex(window: seconds)
        return spectralMetrics(beatTimes: Array(beatTimes[i...]), rrMs: Array(values[i...]))
    }
}
