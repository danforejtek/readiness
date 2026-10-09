import Foundation
import HRVCore
import SwiftData

struct DayAssessment: Identifiable {
    let morning: Morning
    let assessment: Assessment
    var id: UUID { morning.id }
    var day: Date { Readiness.calendar.startOfDay(for: morning.date) }
}

/// Queries and conversions around the `Morning` store.
enum MorningStore {
    /// One morning per calendar day (best signal quality wins), oldest first.
    static func dailyMornings(_ mornings: [Morning]) -> [Morning] {
        var perDay: [Date: Morning] = [:]
        for m in mornings {
            let day = Readiness.calendar.startOfDay(for: m.date)
            if let prev = perDay[day], prev.artefactPct <= m.artefactPct { continue }
            perDay[day] = m
        }
        return perDay.keys.sorted().map { perDay[$0]! }
    }

    /// Index of the baseline period a day belongs to: 0 before the first reset, 1 after it, …
    static func period(of date: Date, resets: [Date]) -> Int {
        let day = Readiness.calendar.startOfDay(for: date)
        return resets.filter { $0 <= day }.count
    }

    /// Every morning assessed against the history of its own baseline period (`AppSettings.baselineResets`),
    /// so a reset starts a fresh baseline while earlier mornings keep the verdicts they had.
    static func dayAssessments(_ mornings: [Morning], resets: [Date]) -> [DayAssessment] {
        let daily = dailyMornings(mornings)
        let periods = Dictionary(grouping: daily) { period(of: $0.date, resets: resets) }
        return periods.keys.sorted().flatMap { key -> [DayAssessment] in
            let ms = periods[key]!
            return zip(ms, Readiness.assessAll(ms.map(\.dayRecord))).map { DayAssessment(morning: $0, assessment: $1) }
        }
    }

    /// Assessment of a specific morning: it stands in for its calendar day, the other days come from the history
    /// of the same baseline period.
    static func assessment(for morning: Morning, in mornings: [Morning], resets: [Date]) -> Assessment {
        let day = Readiness.calendar.startOfDay(for: morning.date)
        let p = period(of: morning.date, resets: resets)
        var daily = dailyMornings(mornings.filter {
            Readiness.calendar.startOfDay(for: $0.date) != day && period(of: $0.date, resets: resets) == p
        })
        daily.append(morning)
        daily.sort { $0.date < $1.date }
        let index = daily.firstIndex { $0.id == morning.id } ?? daily.count - 1
        return Readiness.assess(daily.map(\.dayRecord), index: index)
    }

    /// Bring mornings stored by older versions up to date, at launch:
    /// - `breakIndices` (differences across rejected beats) for mornings with raw intervals, recovered by re-running
    ///   the artefact filter (`Morning.backfillBreaks`), with SD1/SD2 recomputed; clean mornings are untouched;
    /// - SD1/SD2 and the stress index on mornings with beats stored before those existed.
    /// Imported rows without beats stay empty. Idempotent. Returns the number of mornings updated.
    @discardableResult
    static func backfillBeatDerived(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<Morning>())) ?? []
        var updated = 0
        for m in all {
            var changed = false
            if m.breakIndices.isEmpty, !m.allRR.isEmpty { changed = m.backfillBreaks() }
            if m.sd1 == nil, m.rrMs.count >= 3 { m.fillBeatDerived(); changed = true }
            if changed { updated += 1 }
        }
        if updated > 0 { try? context.save() }
        return updated
    }

    /// Whether a measurement (not demo data) exists for today; used to skip today's reminder.
    static func measuredToday(in context: ModelContext, now: Date = Date()) -> Bool {
        let start = Calendar.current.startOfDay(for: now)
        let fetch = FetchDescriptor<Morning>(predicate: #Predicate { $0.date >= start && $0.source != "demo" })
        return ((try? context.fetchCount(fetch)) ?? 0) > 0
    }

    /// Import `readiness.csv` text. Rows whose minute already exists are skipped. Returns the number inserted.
    @discardableResult
    static func importCSV(_ text: String, into context: ModelContext, source: String = "import") throws -> Int {
        let existing = try context.fetch(FetchDescriptor<Morning>())
        var minutes = Set(existing.map { Int($0.date.timeIntervalSince1970 / 60) })
        var inserted = 0
        for row in CSV.parse(text).rows {
            guard let m = Morning(csvRow: row, source: source) else { continue }
            let minute = Int(m.date.timeIntervalSince1970 / 60)
            guard !minutes.contains(minute) else { continue }
            minutes.insert(minute)
            context.insert(m)
            inserted += 1
        }
        try context.save()
        return inserted
    }

    static func exportCSV(_ mornings: [Morning]) -> String {
        ReadinessCSV.text(rows: mornings.sorted { $0.date < $1.date }.map(\.csvRow))
    }

    /// Every received interval (artefacts included) per morning, so the Mac can re-run the artefact filter:
    /// `date,elapsed_s,rr_ms`, with `date` matching the readiness export.
    static func exportBeatsCSV(_ mornings: [Morning]) -> String {
        var lines = ["date,elapsed_s,rr_ms"]
        for m in mornings.sorted(by: { $0.date < $1.date }) {
            let date = Morning.csvDateFormatter.string(from: m.date)
            let pairs = m.allRR.isEmpty ? Array(zip(m.beatTimes, m.rrMs)) : Array(zip(m.allElapsed, m.allRR))
            for (t, rr) in pairs { lines.append("\(date),\(String(format: "%.3f", t)),\(String(format: "%.1f", rr))") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func fixtureText(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "csv") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let fixtureSessions = ["morning-session", "desk-session"]
}
