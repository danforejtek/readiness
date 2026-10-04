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

    static func dayAssessments(_ mornings: [Morning]) -> [DayAssessment] {
        let daily = dailyMornings(mornings)
        let assessments = Readiness.assessAll(daily.map(\.dayRecord))
        return zip(daily, assessments).map { DayAssessment(morning: $0, assessment: $1) }
    }

    /// Assessment of a specific morning: it stands in for its calendar day, the other days come from the history.
    static func assessment(for morning: Morning, in mornings: [Morning]) -> Assessment {
        let day = Readiness.calendar.startOfDay(for: morning.date)
        var daily = dailyMornings(mornings.filter { Readiness.calendar.startOfDay(for: $0.date) != day })
        daily.append(morning)
        daily.sort { $0.date < $1.date }
        let index = daily.firstIndex { $0.id == morning.id } ?? daily.count - 1
        return Readiness.assess(daily.map(\.dayRecord), index: index)
    }

    /// Fill SD1/SD2 and the stress index on mornings stored before they existed. Only mornings with beats
    /// can be filled; imported rows without beats stay empty. Returns the number of mornings updated.
    @discardableResult
    static func backfillBeatDerived(in context: ModelContext) -> Int {
        let fetch = FetchDescriptor<Morning>(predicate: #Predicate { $0.sd1 == nil })
        let missing = ((try? context.fetch(fetch)) ?? []).filter { $0.rrMs.count >= 3 }
        for m in missing { m.fillBeatDerived() }
        if !missing.isEmpty { try? context.save() }
        return missing.count
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
