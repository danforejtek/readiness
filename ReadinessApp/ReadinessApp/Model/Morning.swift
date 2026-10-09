import Foundation
import HRVCore
import SwiftData

/// One morning measurement (or an imported row). Stores the beats so detail charts and re-analysis work offline.
@Model
final class Morning {
    @Attribute(.unique) var id: UUID
    var date: Date
    var durationS: Double
    var settleS: Double
    var beats: Int
    var artefacts: Int
    var meanHR: Double
    var meanRR: Double
    var rmssd: Double
    var lnRMSSD: Double
    var sdnn: Double
    var pnn50: Double
    var artefactPct: Double
    var quality: String
    var lfMs2: Double?
    var hfMs2: Double?
    var lfHf: Double?
    var breathingBpm: Double?
    /// Accepted RR intervals (ms) and their beat times (s) – empty for imported rows.
    var rrMs: [Double]
    var beatTimes: [Double]
    /// Every received interval during the measurement window, including artefacts, with packet elapsed time.
    var allRR: [Double]
    var allElapsed: [Double]
    var source: String
    var deviceName: String
    /// Whether this morning's HRV and resting HR were written to Apple Health.
    var healthSaved: Bool = false
    /// Morning check-in (1 awful … 5 great) and context tags; collected for tuning, not used by the verdict.
    var feeling: Int?
    var tags: [String] = []
    /// Poincaré SD1/SD2 (ms) and Baevsky's stress index from the accepted beats; nil for imported rows without them.
    /// Mornings stored before these existed are filled in by `MorningStore.backfillBeatDerived`.
    var sd1: Double? = nil
    var sd2: Double? = nil
    var stressIndex: Double? = nil
    /// Indices i of `rrMs` whose interval directly follows a rejected one (`RRBuffer.breaks`): rrMs[i] − rrMs[i−1]
    /// spans a removed beat and is left out of RMSSD, pNN50 and SD1. Empty for imported rows and clean mornings;
    /// mornings stored before it existed are filled in by `backfillBreaks()`.
    var breakIndices: [Int] = []

    init(date: Date, metrics m: HRVMetrics, spectral sp: SpectralMetrics?, settleS: Double,
         rrMs: [Double], beatTimes: [Double], allRR: [Double], allElapsed: [Double], breakIndices: [Int] = [],
         source: String, deviceName: String) {
        id = UUID()
        self.date = date
        durationS = m.durationS
        self.settleS = settleS
        beats = m.n
        artefacts = m.artefacts
        meanHR = m.meanHR
        meanRR = m.meanRR
        rmssd = m.rmssd
        lnRMSSD = m.lnRMSSD
        sdnn = m.sdnn
        pnn50 = m.pnn50
        artefactPct = m.artefactPct
        quality = Morning.quality(forArtefactPct: m.artefactPct)
        lfMs2 = sp?.lfMs2
        hfMs2 = sp?.hfMs2
        lfHf = sp.flatMap { $0.lfHf.isFinite ? $0.lfHf : nil }
        breathingBpm = sp?.breathingRateBpm
        self.rrMs = rrMs
        self.beatTimes = beatTimes
        self.allRR = allRR
        self.allElapsed = allElapsed
        self.breakIndices = breakIndices
        self.source = source
        self.deviceName = deviceName
        fillBeatDerived()
    }

    /// Compute SD1/SD2 (skipping differences across rejected beats) and the stress index from the stored beats.
    func fillBeatDerived() {
        let pc = poincare(rr: rrMs, breaks: breakIndices)
        sd1 = pc?.sd1
        sd2 = pc?.sd2
        stressIndex = HRVCore.stressIndex(rr: rrMs)
    }

    /// The artefact filter re-run over every received interval of the measurement window, as
    /// `MeasurementSession` fed it (intervals from the end of the settle phase on). nil without raw intervals.
    func refilter() -> RRBuffer? {
        guard !allRR.isEmpty else { return nil }
        let buffer = RRBuffer()
        for (t, rr) in zip(allElapsed, allRR) where t >= settleS { buffer.add(rr, at: t) }
        return buffer
    }

    /// For mornings stored before `breakIndices` existed: recover them by re-running the filter, then recompute
    /// SD1/SD2. Only when the re-run rejects beats and reproduces the stored beats exactly, so clean mornings (and
    /// ones filtered by an older rule) are left untouched. RMSSD and the verdict inputs stay as stored.
    /// Returns true when the morning changed.
    @discardableResult
    func backfillBreaks() -> Bool {
        guard breakIndices.isEmpty, let buffer = refilter(), buffer.artefacts > 0, !buffer.breaks.isEmpty,
              buffer.values == rrMs else { return false }
        breakIndices = buffer.breaks
        fillBeatDerived()
        return true
    }

    /// From a `readiness.csv` row written by the Mac tool or exported by this app.
    init?(csvRow row: [String: String], source: String = "import") {
        func d(_ k: String) -> Double? { row[k].flatMap { $0.isEmpty ? nil : Double($0) } }
        guard let s = row["date"], let when = Morning.csvDateFormatter.date(from: s),
              let ln = d("ln_rmssd"), let hr = d("mean_hr") else { return nil }
        let beatCount = Int(d("beats") ?? 0)
        let artPct = d("artefact_pct") ?? 0
        id = UUID()
        date = when
        durationS = d("duration_s") ?? 0
        settleS = d("settle_s") ?? 0
        beats = beatCount
        artefactPct = artPct
        artefacts = Int((Double(beatCount) * artPct / max(1, 100 - artPct)).rounded())
        meanHR = hr
        meanRR = d("mean_rr_ms") ?? 60000 / hr
        rmssd = d("rmssd_ms") ?? exp(ln)
        lnRMSSD = ln
        sdnn = d("sdnn_ms") ?? 0
        pnn50 = d("pnn50_pct") ?? 0
        quality = row["quality"].flatMap { $0.isEmpty ? nil : $0 } ?? Morning.quality(forArtefactPct: artPct)
        lfMs2 = d("lf_ms2")
        hfMs2 = d("hf_ms2")
        lfHf = d("lf_hf")
        breathingBpm = d("breathing_bpm")
        rrMs = []
        beatTimes = []
        allRR = []
        allElapsed = []
        let rowSource = row["source"]?.trimmingCharacters(in: .whitespaces) ?? ""
        self.source = rowSource.isEmpty ? source : rowSource
        deviceName = ""
        feeling = d("feeling").map { Int($0) }.flatMap { (1...5).contains($0) ? $0 : nil }
        tags = (row["tags"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        sd1 = d("sd1_ms")
        sd2 = d("sd2_ms")
        stressIndex = d("stress_index")
    }

    static func quality(forArtefactPct pct: Double) -> String { pct < 5 ? "good" : pct < 15 ? "fair" : "poor" }

    static let csvDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = ReadinessCSV.dateFormat
        return f
    }()

    var hasBeats: Bool { rrMs.count >= 2 }

    var dayRecord: DayRecord {
        DayRecord(when: date, lnRMSSD: lnRMSSD, rmssd: rmssd, meanHR: meanHR, sdnn: sdnn, beats: beats,
                  artefactPct: artefactPct, hfMs2: hfMs2, lfMs2: lfMs2, breathingRate: breathingBpm,
                  meanRR: meanRR, sd1: sd1, sd2: sd2, stressIndex: stressIndex)
    }

    var csvRow: [String: String] {
        func s(_ x: Double?, _ digits: Int) -> String { x.map { String(format: "%.\(digits)f", $0) } ?? "" }
        return [
            "date": Morning.csvDateFormatter.string(from: date), "duration_s": s(durationS, 0), "beats": String(beats),
            "mean_hr": s(meanHR, 1), "mean_rr_ms": s(meanRR, 1), "rmssd_ms": s(rmssd, 1), "ln_rmssd": s(lnRMSSD, 2),
            "sdnn_ms": s(sdnn, 1), "pnn50_pct": s(pnn50, 1), "artefact_pct": s(artefactPct, 1), "quality": quality,
            "lf_ms2": s(lfMs2, 0), "hf_ms2": s(hfMs2, 0), "lf_hf": s(lfHf, 2), "breathing_bpm": s(breathingBpm, 1),
            "settle_s": s(settleS, 0),
            "feeling": feeling.map(String.init) ?? "", "tags": tags.joined(separator: ";"), "source": source,
            "sd1_ms": s(sd1, 1), "sd2_ms": s(sd2, 1), "stress_index": s(stressIndex, 1),
        ]
    }
}
