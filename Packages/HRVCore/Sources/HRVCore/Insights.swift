import Foundation

/// The user-facing half of `hrmon analyze`: does the verdict match how you feel, what moves your mornings,
/// does the illness warning catch sick days, and is the protocol consistent. Numbers only; wording is the app's.
/// The what-if and artefact-filter sections stay on the Mac: they only matter when changing the model's defaults.

/// One assessed morning with its check-in.
public struct InsightDay: Sendable {
    public let assessment: Assessment
    /// 1 awful … 5 great; nil when not checked in.
    public let feeling: Int?
    public let tags: [String]

    public init(assessment: Assessment, feeling: Int?, tags: [String]) {
        self.assessment = assessment; self.feeling = feeling; self.tags = tags
    }

    var day: Date { assessment.record.day }
}

public struct InsightsReport: Sendable {
    public struct Routine: Sendable, Equatable {
        public let measuredDays: Int
        /// Calendar days from the first to the last morning, both included.
        public let spanDays: Int
        /// Median measurement time, minutes after midnight.
        public let typicalMinute: Int
        /// Interquartile range of measurement times (minutes): half of all mornings fall within this window.
        public let spreadMinutes: Double
        public let checkIns: Int

        public var coverage: Double { spanDays > 0 ? Double(measuredDays) / Double(spanDays) : 0 }
        public var consistentTime: Bool { spreadMinutes <= 60 }
        public var enoughDays: Bool { coverage >= 0.7 }
    }

    public struct StatusFeeling: Sendable, Equatable {
        public let status: ReadinessStatus
        public let mornings: Int
        public let meanFeeling: Double?
    }

    public struct FeelingMatch: Sendable, Equatable {
        public enum Agreement: Sendable, Equatable { case tracks, loose, notYet }
        public let byStatus: [StatusFeeling]
        /// Spearman rank correlation of score vs feeling.
        public let rho: Double?
        public let pairs: Int

        /// Fewer than two weeks of scored check-ins: a first impression only.
        public var preliminary: Bool { pairs < Insights.solidPairs }
        public var agreement: Agreement {
            guard let rho else { return .notYet }
            return rho >= 0.3 ? .tracks : rho >= 0.1 ? .loose : .notYet
        }
    }

    public struct TagEffect: Sendable, Equatable {
        public let tag: String
        public let mornings: Int
        /// Mean RMSSD on tagged mornings vs your normal, in % (exp of the lnRMSSD gap); others for comparison.
        public let hrvPct: Double
        public let othersHrvPct: Double?
        /// Mean resting HR on tagged mornings minus your normal, in bpm; others for comparison.
        public let hrBpm: Double
        public let othersHrBpm: Double?
        /// The same in z (standard deviations), as in the Mac report.
        public let zHRV: Double
        public let zHR: Double
    }

    public struct IllnessCheck: Sendable, Equatable {
        /// Sick-tagged days with a warning within ±2 days.
        public let caught: [Date]
        public let missed: [Date]
        /// Warning days with no sick tag within ±2 days.
        public let unexplained: [Date]
    }

    public struct Signal: Sendable, Equatable {
        public let medianArtefactPct: Double
        public let p90ArtefactPct: Double
        public let lowConfidence: Int
        public let mornings: Int
        /// Day-to-day coefficient of variation of lnRMSSD (%); 3–8 % is typical with a consistent protocol.
        public let lnCV: Double?
    }

    public let mornings: Int
    public let routine: Routine?
    public let feeling: FeelingMatch?
    public let tags: [TagEffect]
    public let illness: IllnessCheck?
    public let signal: Signal?
}

public enum Insights {
    /// Check-ins wanted before the insights are considered settled (four weeks).
    public static let targetCheckIns = 28
    /// Scored mornings with a feeling before the verdict-vs-feeling card shows at all.
    public static let minPairs = 7
    public static let solidPairs = 14
    /// Tagged and untagged scored mornings needed before a tag's effect is shown.
    public static let minTagged = 2
    public static let tagOrder = ["poor_sleep", "alcohol", "sick", "hard_training", "stress", "late_meal"]

    /// `days` one per calendar day, oldest first (as from `Readiness.assessAll`).
    public static func report(_ days: [InsightDay], calendar: Calendar = Readiness.calendar) -> InsightsReport {
        InsightsReport(mornings: days.count,
                       routine: routine(days, calendar: calendar),
                       feeling: feelingMatch(days),
                       tags: tagEffects(days),
                       illness: illnessCheck(days, calendar: calendar),
                       signal: signal(days))
    }

    static func routine(_ days: [InsightDay], calendar: Calendar) -> InsightsReport.Routine? {
        guard let first = days.first, let last = days.last, days.count >= 3 else { return nil }
        let span = (calendar.dateComponents([.day], from: first.day, to: last.day).day ?? 0) + 1
        // Minutes after 04:00, so measurements just before and after midnight count as close together.
        let minutes = days.map { d -> Double in
            let c = calendar.dateComponents([.hour, .minute], from: d.assessment.record.when)
            return Double(((c.hour ?? 0) * 60 + (c.minute ?? 0) - 240 + 1440) % 1440)
        }
        let median = (Int(quantile(minutes, 0.5).rounded()) + 240) % 1440
        return .init(measuredDays: days.count, spanDays: span, typicalMinute: median,
                     spreadMinutes: quantile(minutes, 0.75) - quantile(minutes, 0.25),
                     checkIns: days.filter { $0.feeling != nil }.count)
    }

    static func feelingMatch(_ days: [InsightDay]) -> InsightsReport.FeelingMatch? {
        let pairs = days.compactMap { d -> (Assessment, Int)? in
            guard let f = d.feeling, d.assessment.score != nil else { return nil }
            return (d.assessment, f)
        }
        guard pairs.count >= minPairs else { return nil }
        let byStatus = [ReadinessStatus.ready, .moderate, .rest].map { s -> InsightsReport.StatusFeeling in
            let fs = pairs.filter { $0.0.status == s }.map { Double($0.1) }
            return .init(status: s, mornings: fs.count, meanFeeling: fs.isEmpty ? nil : Stats.mean(fs))
        }
        let rho = spearman(pairs.map { Double($0.0.score!) }, pairs.map { Double($0.1) })
        return .init(byStatus: byStatus, rho: rho, pairs: pairs.count)
    }

    static func tagEffects(_ days: [InsightDay]) -> [InsightsReport.TagEffect] {
        let scored = days.filter { $0.assessment.zHRV != nil }
        func hrvPct(_ a: Assessment) -> Double { 100 * (exp(a.record.lnRMSSD - a.lnMean!) - 1) }
        func hrGap(_ a: Assessment) -> Double { a.record.meanHR - a.hrMean! }
        return tagOrder.compactMap { tag in
            let with = scored.filter { $0.tags.contains(tag) }.map(\.assessment)
            let without = scored.filter { !$0.tags.contains(tag) }.map(\.assessment)
            guard with.count >= minTagged, without.count >= minTagged else { return nil }
            return .init(tag: tag, mornings: with.count,
                         hrvPct: Stats.mean(with.map(hrvPct)), othersHrvPct: Stats.mean(without.map(hrvPct)),
                         hrBpm: Stats.mean(with.map(hrGap)), othersHrBpm: Stats.mean(without.map(hrGap)),
                         zHRV: Stats.mean(with.map { $0.zHRV! }), zHR: Stats.mean(with.map { $0.zHR! }))
        }
    }

    static func illnessCheck(_ days: [InsightDay], calendar: Calendar) -> InsightsReport.IllnessCheck? {
        let sick = days.filter { $0.tags.contains("sick") }.map(\.day)
        let flagged = days.filter { $0.assessment.illness }.map(\.day)
        guard !sick.isEmpty || !flagged.isEmpty else { return nil }
        func near(_ day: Date, _ others: [Date]) -> Bool {
            others.contains { abs(calendar.dateComponents([.day], from: day, to: $0).day ?? 99) <= 2 }
        }
        return .init(caught: sick.filter { near($0, flagged) },
                     missed: sick.filter { !near($0, flagged) },
                     unexplained: flagged.filter { !near($0, sick) })
    }

    static func signal(_ days: [InsightDay]) -> InsightsReport.Signal? {
        guard days.count >= 3 else { return nil }
        let arts = days.map(\.assessment.record.artefactPct)
        let ln = days.map(\.assessment.record.lnRMSSD)
        let mean = Stats.mean(ln)
        return .init(medianArtefactPct: quantile(arts, 0.5), p90ArtefactPct: quantile(arts, 0.9),
                     lowConfidence: days.filter { $0.assessment.record.lowQuality }.count, mornings: days.count,
                     lnCV: mean > 0 ? 100 * Stats.stdev(ln) / mean : nil)
    }

    /// Rank correlation, ties get average ranks; nil when undefined. Port of `analyze.spearman`.
    public static func spearman(_ xs: [Double], _ ys: [Double]) -> Double? {
        guard xs.count >= 3, xs.count == ys.count else { return nil }
        func ranks(_ v: [Double]) -> [Double] {
            let order = v.indices.sorted { v[$0] < v[$1] }
            var r = [Double](repeating: 0, count: v.count)
            var i = 0
            while i < order.count {
                var j = i
                while j + 1 < order.count, v[order[j + 1]] == v[order[i]] { j += 1 }
                for k in i...j { r[order[k]] = Double(i + j) / 2 + 1 }
                i = j + 1
            }
            return r
        }
        let rx = ranks(xs), ry = ranks(ys)
        let mx = Stats.mean(rx), my = Stats.mean(ry)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(rx, ry) { sxy += (a - mx) * (b - my); sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my) }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : nil
    }

    /// Linear-interpolated quantile, `q` in 0…1. Port of `analyze.quantile`.
    public static func quantile(_ xs: [Double], _ q: Double) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return .nan }
        let pos = Double(s.count - 1) * q
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }
}
