import Foundation

/// Readiness and illness assessment from the daily morning HRV history. Port of `hrmon.readiness`.
///
/// Baseline = mean/SD of lnRMSSD and resting HR over the previous `baselineDays` (excluding today),
/// normal range = mean ± 0.5 SD, 7-day rolling lnRMSSD average, z-scores drive the verdict.
/// A raised resting HR with suppressed HRV raises the illness warning. Training heuristic, not medical advice.
/// Regeneration and Stress (0–10, 5 = your normal) are Kubios-style PNS/SNS indices scored against the same
/// personal baseline: Regeneration from mean RR, RMSSD and SD1; Stress from mean HR, √SI and SD2 (reversed).
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

    public var lowQuality: Bool { artefactPct > 15.0 || beats < 60 }
    public var day: Date { Readiness.calendar.startOfDay(for: when) }
}

/// Today's value against the baseline average and against the previous measured morning, in %.
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
    public var baselineN: Int
    public var lnMean: Double?
    public var lnSD: Double?
    /// 7-day rolling mean of lnRMSSD including today.
    public var lnWeek: Double?
    public var hrMean: Double?
    public var hrSD: Double?
    public var zHRV: Double?
    public var zHR: Double?
    public var illness = false
    public var illnessStreak = 0
    public var lowConfidence = false
    public var notes: [String] = []
    /// 0–10, 5 = your normal; high Regeneration is good (parasympathetic), high Stress is bad (sympathetic).
    public var regeneration: Double?
    public var stress: Double?
    public var zRegeneration: Double?
    public var zStress: Double?
    public var lnChange = Comparison()
    public var hrChange = Comparison()
    /// "vs average" is against 5, the baseline by definition.
    public var regenerationChange = Comparison()
    public var stressChange = Comparison()

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
    public static let lnSDFloor = 0.05
    public static let hrSDFloor = 1.5
    // Regeneration / Stress, same defaults as `Params` in hrmon/readiness.py.
    public static let indexCenter = 5.0
    public static let indexScale = 2.0
    public static let rrSDFloor = 25.0
    public static let rmssdSDFloor = 2.5
    public static let sd1SDFloor = 1.8
    public static let sqrtSISDFloor = 0.2
    public static let sd2SDFloor = 3.0
    /// Calendar used for day arithmetic; Gregorian in the current time zone by default.
    nonisolated(unsafe) public static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    static func daysBetween(_ earlier: Date, _ later: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: earlier), to: calendar.startOfDay(for: later)).day ?? 0
    }

    private typealias Component = (value: @Sendable (DayRecord) -> Double?, floor: Double, sign: Double)

    private static func positive(_ x: Double?) -> Double? { x.flatMap { $0 > 0 ? $0 : nil } }

    // Order matters for parity with `_components` in Python.
    private static let regenerationComponents: [Component] = [
        ({ positive($0.meanRR) }, rrSDFloor, 1),
        ({ positive($0.rmssd) }, rmssdSDFloor, 1),
        ({ positive($0.sd1) }, sd1SDFloor, 1),
    ]
    private static let stressComponents: [Component] = [
        ({ positive($0.meanHR) }, hrSDFloor, 1),
        ({ positive($0.stressIndex).map { $0.squareRoot() } }, sqrtSISDFloor, 1),
        ({ positive($0.sd2) }, sd2SDFloor, -1),   // less long-term variability = more sympathetic
    ]

    /// Regeneration and Stress z: the mean z-score of the components that today and at least `minBaselineDays`
    /// baseline days have (same window as the verdict, today excluded). Port of `ans_z`.
    public static func ansZ(_ records: [DayRecord], index: Int, baselineDays: Int = 60) -> (regeneration: Double?, stress: Double?) {
        let today = records[index]
        let history = records[..<index].filter { daysBetween($0.when, today.when) <= baselineDays }
        func meanZ(_ parts: [Component]) -> Double? {
            var zs: [Double] = []
            for c in parts {
                let hist = history.compactMap(c.value)
                guard let v = c.value(today), hist.count >= minBaselineDays else { continue }
                zs.append(c.sign * (v - Stats.mean(hist)) / max(Stats.stdev(hist), c.floor))
            }
            return zs.isEmpty ? nil : Stats.mean(zs)
        }
        return (meanZ(regenerationComponents), meanZ(stressComponents))
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

    /// Assess the record at `index` (negative counts from the end) against the records before it.
    public static func assess(_ records: [DayRecord], index: Int = -1, baselineDays: Int = 60) -> Assessment {
        let idx = index < 0 ? index + records.count : index
        let today = records[idx]
        let history = records[..<idx].filter { daysBetween($0.when, today.when) <= baselineDays }
        var a = Assessment(record: today, status: .baseline, score: nil, baselineN: history.count)
        a.lowConfidence = today.lowQuality
        let week = records[...idx].filter { let d = daysBetween($0.when, today.when); return d >= 0 && d < 7 }.map(\.lnRMSSD)
        a.lnWeek = week.isEmpty ? nil : Stats.mean(week)

        let z = ansZ(records, index: idx, baselineDays: baselineDays)
        a.zRegeneration = z.regeneration; a.zStress = z.stress
        a.regeneration = scaleIndex(z.regeneration); a.stress = scaleIndex(z.stress)
        let prev: DayRecord? = idx > 0 ? records[idx - 1] : nil
        let prevZ: (regeneration: Double?, stress: Double?) = idx > 0 ? ansZ(records, index: idx - 1, baselineDays: baselineDays) : (nil, nil)
        a.regenerationChange = Comparison(vsAveragePct: pctChange(a.regeneration, indexCenter),
                                          vsLastPct: pctChange(a.regeneration, scaleIndex(prevZ.regeneration)))
        a.stressChange = Comparison(vsAveragePct: pctChange(a.stress, indexCenter),
                                    vsLastPct: pctChange(a.stress, scaleIndex(prevZ.stress)))
        a.lnChange = Comparison(vsLastPct: pctChange(today.lnRMSSD, prev?.lnRMSSD))
        a.hrChange = Comparison(vsLastPct: pctChange(today.meanHR, prev?.meanHR))

        if history.count < minBaselineDays {
            a.notes.append("Building your baseline: \(history.count) of \(minBaselineDays) mornings recorded. Verdicts start after a week of mornings measured the same way.")
            if a.lowConfidence {
                a.notes.append("Noisy reading (\(f0(today.artefactPct)) % of beats rejected, \(today.beats) clean beats). Tighten the band on the inner forearm and keep still, so your baseline starts from clean mornings.")
            }
            return a
        }

        let lnVals = history.map(\.lnRMSSD)
        let hrVals = history.map(\.meanHR)
        let lnMean = Stats.mean(lnVals), lnSD = max(Stats.stdev(lnVals), lnSDFloor)
        let hrMean = Stats.mean(hrVals), hrSD = max(Stats.stdev(hrVals), hrSDFloor)
        a.lnMean = lnMean; a.lnSD = lnSD; a.hrMean = hrMean; a.hrSD = hrSD
        let zHRV = (today.lnRMSSD - lnMean) / lnSD
        let zHR = (today.meanHR - hrMean) / hrSD
        a.zHRV = zHRV; a.zHR = zHR
        a.lnChange.vsAveragePct = pctChange(today.lnRMSSD, lnMean)
        a.hrChange.vsAveragePct = pctChange(today.meanHR, hrMean)

        let composite = 0.65 * zHRV - 0.35 * zHR
        a.score = Int(max(0, min(100, (75 + 15 * composite).rounded())))

        let hrUp = zHR >= 1.5 && today.meanHR - hrMean >= 4.0
        a.illness = (hrUp && zHRV <= -1.0) || zHR >= 2.5
        if a.illness {
            var streak = 1
            var j = idx - 1
            while j >= 0, j > idx - 4 {
                guard assess(records, index: j, baselineDays: baselineDays).illness else { break }
                streak += 1
                j -= 1
            }
            a.illnessStreak = streak
        }

        let weekLow = a.lnWeek.map { $0 < lnMean - 0.5 * lnSD } ?? false

        if a.illness || zHRV <= -1.5 || zHR >= 1.5 || (zHRV <= -1.0 && zHR >= 1.0) {
            a.status = .rest
        } else if zHRV < -0.5 || zHR > 1.0 || weekLow {
            a.status = .moderate
        } else {
            a.status = .ready
        }

        if a.illness {
            let gap = f0(today.meanHR - hrMean)
            let days = a.illnessStreak > 1 ? " for \(a.illnessStreak) days in a row" : ""
            if zHRV <= -1.0 {
                a.notes.append("Resting HR is \(gap) bpm above your normal and HRV is below your normal\(days). This combination often appears a day or two before a cold or other infection, or after heavy stress. Take it easy, drink enough, and watch for symptoms.")
            } else {
                a.notes.append("Resting HR is \(gap) bpm above your normal\(days), far outside your usual range. Infection, heavy stress, a late meal or alcohol can all do this. Take it easy and watch for symptoms.")
            }
        }
        if weekLow {
            a.notes.append("Your 7-day HRV average is below your normal range. Fatigue has been building up over several days, so plan an easier week.")
        }
        if zHRV >= 1.5 && zHR <= -1.5 {
            a.notes.append("HRV is unusually high and resting HR unusually low. Usually that means good recovery. If you still feel flat or heavy-legged, it can be a sign of overreaching after a hard training block.")
        }
        if a.lowConfidence {
            a.notes.append("Noisy reading (\(f0(today.artefactPct)) % of beats rejected, \(today.beats) clean beats). Treat today's verdict with caution. Next time tighten the band on the inner forearm and keep still.")
        }
        if a.status == .ready && a.notes.isEmpty {
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
