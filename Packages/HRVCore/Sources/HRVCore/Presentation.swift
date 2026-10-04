import Foundation

// Presentation rules for the app. They only label numbers that the Python-backed maths already produced,
// so they have no Python counterpart; they live here so they are unit-tested.

public enum MetricDirection: Sendable, Equatable {
    case higherIsBetter, lowerIsBetter
}

/// Where a 0–10 Regeneration or Stress value sits. The bands match the range bars and the verdict:
/// ±1 point = ±0.5 SD = your normal range (4–6), more than 3 points worse = more than 1.5 SD.
public enum IndexLevel: Sendable, Equatable {
    case better, normal, slightlyWorse, clearlyWorse

    public init(value: Double, direction: MetricDirection) {
        let worse = direction == .higherIsBetter ? Readiness.indexCenter - value : value - Readiness.indexCenter
        // values carry one decimal; the small epsilon keeps 4.0 and 6.0 inside the normal band
        if worse > 3 + 1e-9 { self = .clearlyWorse }
        else if worse > 1 + 1e-9 { self = .slightlyWorse }
        else if worse < -1 - 1e-9 { self = .better }
        else { self = .normal }
    }

    /// The normal band on the 0–10 scale.
    public static let normalRange: ClosedRange<Double> = (Readiness.indexCenter - 1)...(Readiness.indexCenter + 1)
}

/// One "▲ 8 % above average" / "▼ 1 % since last measurement" chip.
public struct ChangeChip: Equatable, Sendable {
    public enum Kind: Sendable { case vsAverage, vsLast }

    public let text: String
    /// Short form for narrow places such as under a ring: "▲ 8 % vs avg".
    public let shortText: String
    /// nil when the change rounds to 0 %.
    public let isGood: Bool?

    public init?(pct: Double?, kind: Kind, direction: MetricDirection) {
        guard let pct, pct.isFinite else { return nil }
        let n = Int(abs(pct).rounded())
        guard n > 0 else {
            text = kind == .vsAverage ? "= your average" : "= same as last measurement"
            shortText = kind == .vsAverage ? "= avg" : "= last"
            isGood = nil
            return
        }
        let arrow = pct > 0 ? "▲" : "▼"
        switch kind {
        case .vsAverage:
            text = "\(arrow) \(n) % \(pct > 0 ? "above" : "below") average"
            shortText = "\(arrow) \(n) % vs avg"
        case .vsLast:
            text = "\(arrow) \(n) % since last measurement"
            shortText = "\(arrow) \(n) % vs last"
        }
        isGood = (pct > 0) == (direction == .higherIsBetter)
    }

    /// Both chips of a comparison, average first; missing ones are left out.
    public static func chips(_ c: Comparison, direction: MetricDirection) -> [ChangeChip] {
        [ChangeChip(pct: c.vsAveragePct, kind: .vsAverage, direction: direction),
         ChangeChip(pct: c.vsLastPct, kind: .vsLast, direction: direction)].compactMap { $0 }
    }
}

/// Monday–Sunday of the current week with the measured mornings.
public enum WeekStrip {
    public struct Day: Equatable, Sendable {
        public let date: Date          // start of the day
        public let measured: Bool
        public let isToday: Bool
        public let isFuture: Bool
    }

    /// `measuredDays` may hold any time of day; they are compared by calendar day.
    public static func days(containing today: Date, measuredDays: [Date], calendar: Calendar = Readiness.calendar) -> [Day] {
        var cal = calendar
        cal.firstWeekday = 2   // Monday
        let todayStart = cal.startOfDay(for: today)
        guard let start = cal.dateInterval(of: .weekOfYear, for: todayStart)?.start else { return [] }
        let measured = Set(measuredDays.map { cal.startOfDay(for: $0) })
        return (0..<7).compactMap { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            return Day(date: d, measured: measured.contains(d), isToday: d == todayStart, isFuture: d > todayStart)
        }
    }
}
