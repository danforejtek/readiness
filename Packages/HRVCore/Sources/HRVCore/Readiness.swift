import Foundation

/// Readiness and illness assessment from the daily morning HRV history. Port of `hrmon.readiness`.
///
/// Baseline = mean/SD of lnRMSSD and resting HR over the previous `baselineDays` (excluding today; low-quality
/// mornings left out once at least `minBaselineDays` clean ones exist), normal range = mean ± 0.5 SD,
/// 7-day rolling lnRMSSD average (flags fatigue only with at least `weekMinDays` mornings, Plews 2014),
/// z-scores drive the verdict. Verdicts start after `minBaselineDays` mornings but stay `provisional` until the
/// baseline holds `firmBaselineDays` (Plews 2012/2014; evidence.md A and B); that only adds a note. A morning is low
/// quality above `lowQualityArtefactPct` rejected beats or below `lowQualityBeats` clean ones (evidence.md F).
/// A single morning's HRV only counts from −1 SD (`moderateZHRV`), not from the edge of the
/// ±0.5 SD range: the HRV-guided training trials acted on the 7-day average or on single-day drops of at least 1 SD
/// (Kiviniemi 2007; Plews 2012/2013; docs/evidence.md, sections A and L).
/// A raised resting HR with suppressed HRV often precedes an infection, but alcohol, poor sleep, travel and stress
/// produce it too. One flagged morning (`illnessSignal`) only adds a note; the illness warning needs `illnessMinDays`
/// flagged mornings in a row, as the published detectors use multi-day logic (Mishra 2020, Alavi 2022; evidence.md C).
/// Training heuristic, not medical advice.
/// Regeneration and Stress (0–10, 5 = your normal, 4–6 = ±0.5 SD, 2 points = 1 SD) are scored against the verdict's
/// personal, clean-only baseline. Regeneration = z(lnRMSSD), your HRV against your own normal. Stress is strain /
/// load: ⅔ · z(resting HR) + ⅓ · −z(ln SD2), Naranjo Orellana's (2015) Stress Score 1000/SD2 on the log scale, or
/// z(resting HR) alone without SD2. No short HRV index measures sympathetic activity, so Stress is not called that.
/// See docs/evidence.md, sections G, H and I.
public enum ReadinessStatus: String, Sendable, Codable {
    case ready, moderate, rest, baseline
}

public struct DayRecord: Equatable, Sendable {
    public let when: Date
    public let lnRMSSD: Double
    public let rmssd: Double
    public let meanHR: Double
    public let sdnn: Double
    public let beats: Int
    public let artefactPct: Double
    public let hfMs2: Double?
    public let lfMs2: Double?
    public let breathingRate: Double?
    /// Mean RR (ms), Poincaré SD1/SD2 (ms) and Baevsky's stress index need the beats; old Mac rows lack them.
    public let meanRR: Double?
    public let sd1: Double?
    public let sd2: Double?
    public let stressIndex: Double?

    public init(when: Date, lnRMSSD: Double, rmssd: Double, meanHR: Double, sdnn: Double, beats: Int,
                artefactPct: Double, hfMs2: Double? = nil, lfMs2: Double? = nil, breathingRate: Double? = nil,
                meanRR: Double? = nil, sd1: Double? = nil, sd2: Double? = nil, stressIndex: Double? = nil) {
        self.when = when; self.lnRMSSD = lnRMSSD; self.rmssd = rmssd; self.meanHR = meanHR; self.sdnn = sdnn
        self.beats = beats; self.artefactPct = artefactPct; self.hfMs2 = hfMs2; self.lfMs2 = lfMs2
        self.breathingRate = breathingRate
        self.meanRR = meanRR; self.sd1 = sd1; self.sd2 = sd2; self.stressIndex = stressIndex
    }

    public var lowQuality: Bool { artefactPct > Readiness.lowQualityArtefactPct || beats < Readiness.lowQualityBeats }
    public var day: Date { Readiness.calendar.startOfDay(for: when) }
}

/// Today's value against the baseline average and against the previous measured morning, in %.
/// For HRV (`Assessment.lnChange`) the % is of RMSSD itself, 100 · (e^(Δ lnRMSSD) − 1), not of the log value.
public struct Comparison: Equatable, Sendable {
    public var vsAveragePct: Double?
    public var vsLastPct: Double?
    public init(vsAveragePct: Double? = nil, vsLastPct: Double? = nil) {
        self.vsAveragePct = vsAveragePct; self.vsLastPct = vsLastPct
    }
}

public struct Assessment: Equatable, Sendable {
    public let record: DayRecord
    public var status: ReadinessStatus
    /// 0–100, 75 = your normal day; nil while building the baseline.
    public var score: Int?
    /// Earlier mornings in the baseline window (today excluded); a verdict needs `Readiness.minBaselineDays`.
    public var baselineN: Int
    public var lnMean: Double?
    public var lnSD: Double?
    /// 7-day rolling mean of lnRMSSD including today.
    public var lnWeek: Double?
    /// Mornings in `lnWeek`; it flags fatigue only with at least `Readiness.weekMinDays`.
    public var weekN = 0
    public var hrMean: Double?
    public var hrSD: Double?
    public var zHRV: Double?
    public var zHR: Double?
    /// The illness warning: `illnessStreak` ≥ `Readiness.illnessMinDays`.
    public var illness = false
    /// Today's morning alone matches the illness pattern.
    public var illnessSignal = false
    /// Flagged mornings in a row up to today (0 when today is not flagged).
    public var illnessStreak = 0
    public var lowConfidence = false
    /// A verdict, but from fewer than `Readiness.firmBaselineDays` baseline mornings.
    public var provisional = false
    public var notes: [String] = []
    /// 0–10, 5 = your normal. Regeneration is your HRV (lnRMSSD), high = better recovered than usual; Stress is
    /// strain / load (mostly resting HR, partly SD2), high = more strain than usual.
    public var regeneration: Double?
    public var stress: Double?
    public var zRegeneration: Double?
    public var zStress: Double?
    public var lnChange = Comparison()
    public var hrChange = Comparison()
    /// "vs average" is against 5, the baseline by definition.
    public var regenerationChange = Comparison()
    public var stressChange = Comparison()

    /// Mornings recorded towards the baseline, today included, capped at `Readiness.minBaselineDays`.
    /// Shown to the user; `baselineN` alone is one short because it leaves out the morning just measured.
    public var baselineRecorded: Int { min(baselineN + 1, Readiness.minBaselineDays) }

    public var lnRange: ClosedRange<Double>? {
        guard let m = lnMean, let sd = lnSD else { return nil }
        return (m - 0.5 * sd)...(m + 0.5 * sd)
    }

    public var hrRange: ClosedRange<Double>? {
        guard let m = hrMean, let sd = hrSD else { return nil }
        return (m - 0.5 * sd)...(m + 0.5 * sd)
    }
}

public enum Readiness {
    public static let minBaselineDays = 7
    /// Verdicts with fewer baseline mornings than this are provisional (Plews 2014: a two-week baseline).
    public static let firmBaselineDays = 14
    /// Low confidence above this % of rejected beats (15 until 2026-10-09), or below `lowQualityBeats` clean beats.
    public static let lowQualityArtefactPct = 5.0
    public static let lowQualityBeats = 60
    public static let lnSDFloor = 0.05
    public static let hrSDFloor = 1.5
    public static let illnessBpm = 4.0
    /// Flagged mornings in a row before the illness warning; a single one only adds a note (Mishra 2020, Alavi 2022).
    public static let illnessMinDays = 2
    /// MODERATE when today's HRV z is at or below this (Kiviniemi 2007); the 7-day average keeps the ±0.5 SD range.
    public static let moderateZHRV = -1.0
    /// The 7-day average needs this many mornings in its window before it can flag fatigue (Plews 2014).
    public static let weekMinDays = 3
    // Regeneration / Stress, same defaults as `Params` in hrmon/readiness.py.
    public static let indexCenter = 5.0
    public static let indexScale = 2.0
    public static let stressWeightHR = 2.0 / 3.0
    public static let stressWeightSD2 = 1.0 / 3.0
    public static let lnSD2SDFloor = 0.05
    /// Calendar used for day arithmetic; Gregorian in the current time zone by default.
    nonisolated(unsafe) public static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    static func daysBetween(_ earlier: Date, _ later: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: earlier), to: calendar.startOfDay(for: later)).day ?? 0
    }

    private typealias Component = (value: @Sendable (DayRecord) -> Double?, floor: Double, sign: Double, weight: Double)

    private static func positive(_ x: Double?) -> Double? { x.flatMap { $0 > 0 ? $0 : nil } }

    // Order matters for parity with `_components` in Python.
    private static let regenerationComponents: [Component] = [
        ({ $0.lnRMSSD.isFinite ? $0.lnRMSSD : nil }, lnSDFloor, 1, 1),
    ]
    private static let stressComponents: [Component] = [
        ({ positive($0.meanHR) }, hrSDFloor, 1, stressWeightHR),
        // Naranjo's Stress Score 1000/SD2 on the log scale: ln SS = ln 1000 − ln SD2, so z(ln SS) = −z(ln SD2)
        ({ positive($0.sd2).map { log($0) } }, lnSD2SDFloor, -1, stressWeightSD2),
    ]

    /// Regeneration and Stress z: the weighted mean z-score of the components that today and at least
    /// `minBaselineDays` baseline days have. The baseline is the verdict's (`baseline`: same window, today excluded,
    /// low-quality mornings left out once enough clean ones exist). Port of `ans_z`.
    public static func ansZ(_ records: [DayRecord], index: Int, baselineDays: Int = 60) -> (regeneration: Double?, stress: Double?) {
        let today = records[index]
        let history = baseline(records, index: index, baselineDays: baselineDays).days
        func weightedZ(_ parts: [Component]) -> Double? {
            var num = 0.0, den = 0.0
            for c in parts {
                let hist = history.compactMap(c.value)
                guard let v = c.value(today), hist.count >= minBaselineDays else { continue }
                num += c.weight * c.sign * (v - Stats.mean(hist)) / max(Stats.stdev(hist), c.floor)
                den += c.weight
            }
            return den > 0 ? num / den : nil
        }
        return (weightedZ(regenerationComponents), weightedZ(stressComponents))
    }

    /// z → 0–10 with 5 = your normal: round(clip(5 + 2·z, 0, 10), 1).
    public static func scaleIndex(_ z: Double?) -> Double? {
        guard let z else { return nil }
        return (min(10, max(0, indexCenter + indexScale * z)) * 10).rounded(.toNearestOrEven) / 10
    }

    public static func pctChange(_ value: Double?, _ ref: Double?) -> Double? {
        guard let value, let ref, ref != 0 else { return nil }
        return 100 * (value - ref) / abs(ref)
    }

    /// % change of RMSSD between two lnRMSSD values: 100 · (e^(lnValue − lnRef) − 1).
    public static func rmssdPct(_ lnValue: Double?, _ lnRef: Double?) -> Double? {
        guard let lnValue, let lnRef else { return nil }
        return 100 * (exp(lnValue - lnRef) - 1)
    }

    /// The earlier mornings in the baseline window, and whether low-quality ones were left out: they are once at
    /// least `minBaselineDays` clean mornings exist, otherwise every morning counts. Port of `_baseline`.
    static func baseline(_ records: [DayRecord], index: Int, baselineDays: Int) -> (days: [DayRecord], cleanOnly: Bool) {
        let today = records[index]
        let history = records[..<index].filter { daysBetween($0.when, today.when) <= baselineDays }
        let clean = history.filter { !$0.lowQuality }
        return clean.count >= minBaselineDays ? (clean, true) : (history, false)
    }

    /// lnRMSSD mean and SD, resting HR mean and SD, with the SD floors.
    static func baselineStats(_ base: [DayRecord]) -> (lnMean: Double, lnSD: Double, hrMean: Double, hrSD: Double) {
        let lnVals = base.map(\.lnRMSSD), hrVals = base.map(\.meanHR)
        return (Stats.mean(lnVals), max(Stats.stdev(lnVals), lnSDFloor), Stats.mean(hrVals), max(Stats.stdev(hrVals), hrSDFloor))
    }

    /// Resting HR at least `illnessBpm` above normal, and either raised together with a lowered HRV or far up on its own.
    static func illnessRule(hrGap: Double, zHRV: Double, zHR: Double) -> Bool {
        guard hrGap >= illnessBpm else { return false }
        return (zHR >= 1.5 && zHRV <= -1.0) || zHR >= 2.5
    }

    /// Only the illness flag of the record at `index`: no notes, streak or Regeneration/Stress, so walking back
    /// over a streak stays cheap. Port of `_ill`.
    static func isIll(_ records: [DayRecord], index: Int, baselineDays: Int) -> Bool {
        let base = baseline(records, index: index, baselineDays: baselineDays).days
        guard base.count >= minBaselineDays else { return false }
        let s = baselineStats(base), r = records[index]
        return illnessRule(hrGap: r.meanHR - s.hrMean, zHRV: (r.lnRMSSD - s.lnMean) / s.lnSD, zHR: (r.meanHR - s.hrMean) / s.hrSD)
    }

    /// Assess the record at `index` (negative counts from the end) against the records before it.
    public static func assess(_ records: [DayRecord], index: Int = -1, baselineDays: Int = 60) -> Assessment {
        let idx = index < 0 ? index + records.count : index
        let today = records[idx]
        let (history, cleanOnly) = baseline(records, index: idx, baselineDays: baselineDays)
        var a = Assessment(record: today, status: .baseline, score: nil, baselineN: history.count)
        a.lowConfidence = today.lowQuality
        // today always counts, earlier mornings by the same rule as the baseline; shown with any number of mornings,
        // but it only flags fatigue with at least `weekMinDays` of them
        let week = records[...idx].indices.filter { j in
            let d = daysBetween(records[j].when, today.when)
            return d >= 0 && d < 7 && (j == idx || !(cleanOnly && records[j].lowQuality))
        }.map { records[$0].lnRMSSD }
        a.lnWeek = week.isEmpty ? nil : Stats.mean(week)
        a.weekN = week.count

        let z = ansZ(records, index: idx, baselineDays: baselineDays)
        a.zRegeneration = z.regeneration; a.zStress = z.stress
        a.regeneration = scaleIndex(z.regeneration); a.stress = scaleIndex(z.stress)
        let prev: DayRecord? = idx > 0 ? records[idx - 1] : nil
        let prevZ: (regeneration: Double?, stress: Double?) = idx > 0 ? ansZ(records, index: idx - 1, baselineDays: baselineDays) : (nil, nil)
        a.regenerationChange = Comparison(vsAveragePct: pctChange(a.regeneration, indexCenter),
                                          vsLastPct: pctChange(a.regeneration, scaleIndex(prevZ.regeneration)))
        a.stressChange = Comparison(vsAveragePct: pctChange(a.stress, indexCenter),
                                    vsLastPct: pctChange(a.stress, scaleIndex(prevZ.stress)))
        a.lnChange = Comparison(vsLastPct: rmssdPct(today.lnRMSSD, prev?.lnRMSSD))
        a.hrChange = Comparison(vsLastPct: pctChange(today.meanHR, prev?.meanHR))

        if history.count < minBaselineDays {
            // Today's morning counts: it joins the baseline of the next one.
            let recorded = history.count + 1
            if recorded >= minBaselineDays {
                a.notes.append("Baseline complete: \(recorded) mornings recorded. Your first verdict comes with the next morning.")
            } else {
                a.notes.append("Building your baseline: \(recorded) of \(minBaselineDays) mornings recorded. Verdicts start after a week of mornings measured the same way.")
            }
            if a.lowConfidence {
                a.notes.append("Noisy reading (\(f0(today.artefactPct)) % of beats rejected, \(today.beats) clean beats). Check that the sensor sits snugly with good skin contact and keep still, so your baseline starts from clean mornings.")
            }
            return a
        }

        let (lnMean, lnSD, hrMean, hrSD) = baselineStats(history)
        a.lnMean = lnMean; a.lnSD = lnSD; a.hrMean = hrMean; a.hrSD = hrSD
        let zHRV = (today.lnRMSSD - lnMean) / lnSD
        let zHR = (today.meanHR - hrMean) / hrSD
        a.zHRV = zHRV; a.zHR = zHR
        a.lnChange.vsAveragePct = rmssdPct(today.lnRMSSD, lnMean)
        a.hrChange.vsAveragePct = pctChange(today.meanHR, hrMean)

        let composite = 0.65 * zHRV - 0.35 * zHR
        a.score = Int(max(0, min(100, (75 + 15 * composite).rounded())))
        a.provisional = a.baselineN < firmBaselineDays

        // one morning is a signal, the warning needs `illnessMinDays` of them in a row
        a.illnessSignal = illnessRule(hrGap: today.meanHR - hrMean, zHRV: zHRV, zHR: zHR)
        if a.illnessSignal {
            // consecutive calendar days with the flag, walking back from today
            var j = idx
            while j > 0, daysBetween(records[j - 1].when, records[j].when) == 1,
                  isIll(records, index: j - 1, baselineDays: baselineDays) {
                j -= 1
            }
            a.illnessStreak = idx - j + 1
        }
        a.illness = a.illnessSignal && a.illnessStreak >= illnessMinDays

        let weekLow = week.count >= weekMinDays && (a.lnWeek.map { $0 < lnMean - 0.5 * lnSD } ?? false)

        if a.illness || zHRV <= -1.5 || zHR >= 1.5 || (zHRV <= -1.0 && zHR >= 1.0) {
            a.status = .rest
        } else if zHRV <= moderateZHRV || zHR > 1.0 || weekLow {
            a.status = .moderate
        } else {
            a.status = .ready
        }

        let gap = f0(today.meanHR - hrMean)
        if a.illness {
            let days = a.illnessStreak > 1 ? " for \(a.illnessStreak) days in a row" : ""
            if zHRV <= -1.0 {
                a.notes.append("Resting HR is \(gap) bpm above your normal and HRV is below your normal\(days). This pattern often appears one to three days before a cold or other infection, but alcohol, poor sleep, travel and stress produce it too. Take it easy, drink enough, and watch for symptoms.")
            } else {
                a.notes.append("Resting HR is \(gap) bpm above your normal\(days), far outside your usual range. Infection, alcohol, poor sleep, travel, heavy stress or a late meal can all do this. Take it easy and watch for symptoms.")
            }
        } else if a.illnessSignal {
            let hrv = zHRV <= -1.0 ? " and HRV is below your normal" : ""
            a.notes.append("Resting HR is \(gap) bpm above your normal\(hrv). One morning like this can be alcohol, poor sleep, travel or stress; if it is the same tomorrow the app raises the illness warning.")
        }
        if weekLow {
            a.notes.append("Your 7-day HRV average is below your normal range. Fatigue has been building up over several days, so plan an easier week.")
        }
        if zHRV >= 1.5 && zHR <= -1.5 {
            a.notes.append("HRV is unusually high and resting HR unusually low. Usually that means good recovery. If you still feel flat or heavy-legged, it can be a sign of overreaching after a hard training block.")
        }
        if a.provisional {
            a.notes.append("Your normal range is still settling: it rests on \(a.baselineN) mornings and is firm after \(firmBaselineDays). Treat the verdict as a first indication.")
        }
        if a.lowConfidence {
            a.notes.append("Noisy reading (\(f0(today.artefactPct)) % of beats rejected, \(today.beats) clean beats). Treat today's verdict with caution. Next time check that the sensor sits snugly with good skin contact and keep still.")
        }
        // the provisional note alone does not replace the all-clear
        if a.status == .ready && a.notes.count == (a.provisional ? 1 : 0) {
            a.notes.append("HRV and resting HR are within your normal range. A good day for a hard session.")
        } else if a.status == .moderate && !a.illness {
            a.notes.append("Slightly off your normal. Training is fine, but keep the intensity moderate and listen to your body.")
        } else if a.status == .rest && !a.illness {
            a.notes.append("Clearly off your normal. Make it a recovery day with easy movement only.")
        }
        return a
    }

    public static func assessAll(_ records: [DayRecord], baselineDays: Int = 60) -> [Assessment] {
        records.indices.map { assess(records, index: $0, baselineDays: baselineDays) }
    }

    // Python-compatible "{:.0f}" (round half to even on the decimal value).
    static func f0(_ x: Double) -> String { String(Int(roundHalfEven(x))) }
    static func roundHalfEven(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }
}
